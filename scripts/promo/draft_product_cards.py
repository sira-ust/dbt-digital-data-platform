"""Draft a PRODUCT CARD for each promo item that has a photo or a description (step 2b).

The monthly INPUT file carries, for some items, a product photo and the description
file's text (short description, selling points, notes). The NAV description says
"LAY'S BBQ PORK RIBS FLAVOR"; the pack says "Vị Sườn Nướng BBQ Brazil / Brazil BBQ
Pork Rib", Party Pack. People write what the pack says, and the pack is what tells
this item from its lookalikes (the US "Mesquite BBQ" Stax can is not the Vietnamese
"Vị Thịt Nướng BBQ" one). So the Databricks-hosted model reads the photo and the text
and drafts a card:

    brand_on_pack, product_on_pack, flavor_on_pack   as PRINTED, native script kept
    pack, market, look                                what the pack is and looks like
    pack_text                                         distinctive text printed on it
    lookalikes                                        what is NOT this item
    search_phrases                                    up to 2, from the pack text
    flavor_terms / product_terms                      extra spellings read off the pack

int_promo_items_enriched puts the search phrases FIRST in search_queries and adds the
spellings to the item's terms; the judge gets the whole card (and, for YouTube, the
photo). An item with no photo and no description gets no card and works as before.

RE-DRAFTING IS AUTOMATIC: a card records the version (model / prompt) and a
fingerprint of its inputs (the text and the photo's bytes). A run drafts the latest
month's items with no card, or whose card is from another version or other inputs.
youtube_search.py then re-searches every item whose card is newer than its search.

    python scripts/promo/draft_product_cards.py --dry-run     # list the items to draft
    python scripts/promo/draft_product_cards.py
    python scripts/promo/draft_product_cards.py --backend databricks

Reads the dbt models: run `dbt build --select +int_promo_items_enriched` first.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path.cwd() / "scripts" / "promo"))
try:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
except NameError:
    pass

from promo_common import (  # noqa: E402
    INTERMEDIATE_SCHEMA, LANDING, STAGING_SCHEMA, append_records, dbt_var, ensure_landing, extract_json,
    get_llm_client, landing_path, query, read_photo, split_terms,
)

CARD_PROMPT_VERSION = "v1"
DETAIL_FIELDS = ["brand_stated", "short_description", "selling_points", "detail_notes"]

INSTRUCTIONS = """You describe one grocery product so that a distributor can find social media posts and videos about THIS exact product, and tell it apart from lookalikes. You get the distributor's item record and, when there is one, the product photo.

Return JSON only:
{
 "brand_on_pack": "the brand exactly as printed on the pack, or null",
 "product_on_pack": "the product name as printed, native script kept, English in parentheses when it is not English, or null",
 "flavor_on_pack": "the flavor / variant name exactly as printed, every language on the pack, e.g. 'Vị Sườn Nướng BBQ Brazil / Brazil BBQ Pork Rib', or null",
 "pack": "pack type, badge and net content, e.g. 'bag, Party Pack, 90 g'",
 "market": "the country the pack is made for, from its languages and labels, e.g. 'Vietnam'",
 "look": "one short sentence: colours, logo, pictures on the pack",
 "pack_text": ["distinctive text printed on the pack: names, flavor, slogans, badges"],
 "lookalikes": ["products a post could confuse with this one and that are NOT this item"],
 "search_phrases": ["up to 2 phrases a shopper would type to find videos of this item"],
 "flavor_terms": ["the flavor as written on the pack, lowercase, each language separately"],
 "product_terms": ["the product type as written on the pack, lowercase, each language separately"],
 "notes": "anything a reviewer should check"
}

Rules:
- COPY what the pack says. Never invent a name, flavor, size or slogan the photo or record does not show. When there is no photo, take only what the record states, leave pack_text empty, and say "no photo" in notes.
- The record's description is the distributor's catalog text, uppercase and often truncated; the photo and the description file's text are better evidence.
- search_phrases: the brand plus the flavor as printed, in the pack's main language first (e.g. "lay's sườn nướng bbq brazil"), then the English name on the pack if there is one (e.g. "lay's brazil bbq pork rib"). Lowercase. Never a phrase that would also find the lookalikes. A product line name that sets it apart (e.g. "stax") belongs in the phrase.
- lookalikes: the same brand's other flavors and lines on this promo (listed below the record), the same product made for other markets (another country's edition with a different pack or flavor name), and other sizes when the size is visibly different. Name each one so a reader can recognise it, e.g. "Lay's Stax Mesquite Barbecue (US red canister)".
- flavor_terms / product_terms: only spellings that appear on the pack or in the record, e.g. "sườn nướng", "brazil bbq pork rib", "khoai tây chiên". No generic words that would match other flavors ("bbq" alone, "chips" alone).
- Keep every list short: at most 6 items each."""


def card_version(model: str) -> str:
    return f"{model}/{CARD_PROMPT_VERSION}"


def input_fingerprint(row: dict, photo_bytes: bytes | None) -> str:
    """What a card is drawn from: the description text and the photo. A change to
    either re-drafts the card."""
    h = hashlib.sha1()
    for f in ["promo_description", "promo_size", "origin_code"] + DETAIL_FIELDS:
        h.update(f"{f}={row.get(f) or ''}\n".encode("utf-8"))
    h.update(photo_bytes or b"")
    return h.hexdigest()[:12]


def _photo_bytes(path) -> bytes | None:
    if path is None or str(path).strip() in ("", "nan", "None"):
        return None
    try:
        return Path(str(path)).read_bytes()
    except OSError:
        return None


def _has_detail(row: dict) -> bool:
    return bool(row.get("photo_path")) or any(row.get(f) for f in DETAIL_FIELDS)


def items_needing_cards(backend: str, version: str) -> tuple[list[dict], list[dict]]:
    """(the latest month's items, those that need a card drafted). An item needs one
    when it has a photo or description text and no card, or a card made from another
    version or other inputs."""
    dbx = backend == "databricks"
    rel = f"{INTERMEDIATE_SCHEMA}.int_promo_items_enriched" if dbx else "ust_intermediate.int_promo_items_enriched"
    cards = f"{STAGING_SCHEMA}.stg_promo__product_cards" if dbx else "ust_staging.stg_promo__product_cards"
    rows = query(backend, f"""
        select i.item_no, i.promo_description, i.promo_size, i.origin_code, i.brand_stated,
               i.short_description, i.selling_points, i.detail_notes, i.photo_path,
               i.item_full_description, i.country_of_origin, i.brand,
               c.card_version, c.input_fingerprint
        from {rel} as i
        left join {cards} as c on c.item_no = i.item_no
        where i.promo_month = (select max(promo_month) from {rel})
    """)
    seen, items = set(), []
    for r in rows:
        if r["item_no"] not in seen:
            seen.add(r["item_no"])
            items.append(r)
    todo = []
    for r in items:
        if not _has_detail(r):
            continue
        r["_photo"] = _photo_bytes(r.get("photo_path"))
        r["_fingerprint"] = input_fingerprint(r, r["_photo"])
        if r.get("card_version") != version or r.get("input_fingerprint") != r["_fingerprint"]:
            todo.append(r)
    return items, todo


def _item_prompt(r: dict, month_items: list[dict]) -> str:
    others = [f"{o['item_no']} {o['promo_description']} ({o.get('promo_size') or '-'})"
              for o in month_items if o["item_no"] != r["item_no"]]
    return "\n".join([
        f"item_no: {r.get('item_no')}",
        f"description: {r.get('promo_description')}",
        f"case size: {r.get('promo_size') or '-'}",
        f"catalog description: {r.get('item_full_description') or '-'}",
        f"origin: {r.get('origin_code') or r.get('country_of_origin') or '-'}",
        f"brand stated by the distributor: {r.get('brand_stated') or '-'}",
        f"short description: {r.get('short_description') or '-'}",
        f"selling points: {r.get('selling_points') or '-'}",
        f"notes: {r.get('detail_notes') or '-'}",
        f"photo: {'attached' if r.get('_photo') else 'none'}",
        "",
        "the other items on this month's promo list (some may be lookalikes):",
        *[f"  - {o}" for o in others],
    ])


def _as_list(v, limit=6) -> list[str]:
    items = v if isinstance(v, (list, tuple)) else ([] if v in (None, "") else str(v).split("|"))
    return split_terms([str(x).replace("|", "/") for x in items])[:limit]


def draft_one(client, model: str, version: str, row: dict, month_items: list[dict]) -> dict | None:
    content = _item_prompt(row, month_items)
    photo = read_photo(row.get("photo_path")) if row.get("_photo") else None
    message = [photo, {"type": "text", "text": content}] if photo else content
    data = None
    for _ in range(2):
        resp = client.messages.create(model=model, max_tokens=2000, system=INSTRUCTIONS,
                                      messages=[{"role": "user", "content": message}])
        data = extract_json("".join(getattr(b, "text", "") for b in resp.content))
        if isinstance(data, dict):
            break
    if not isinstance(data, dict):
        print(f"  ! {row['item_no']}: unparseable reply, skipped — re-run to retry")
        return None

    def text(k):
        v = data.get(k)
        return None if v in (None, "", []) else str(v).strip()

    return {
        "item_no": row["item_no"],
        "brand_on_pack": text("brand_on_pack"),
        "product_on_pack": text("product_on_pack"),
        "flavor_on_pack": text("flavor_on_pack"),
        "pack": text("pack"),
        "market": text("market"),
        "look": text("look"),
        "pack_text": "|".join(_as_list(data.get("pack_text"))) or None,
        "lookalikes": "|".join(_as_list(data.get("lookalikes"))) or None,
        "search_phrases": "|".join(p.lower() for p in _as_list(data.get("search_phrases"), 2)) or None,
        "flavor_terms": "|".join(t.lower() for t in _as_list(data.get("flavor_terms"))) or None,
        "product_terms": "|".join(t.lower() for t in _as_list(data.get("product_terms"))) or None,
        "has_photo": "true" if photo else "false",
        "notes": text("notes"),
        "input_fingerprint": row["_fingerprint"],
        "drafted_at": datetime.now(timezone.utc).replace(tzinfo=None).isoformat(sep=" ", timespec="seconds"),
        "card_version": version,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--backend", choices=["local", "databricks"], default="local")
    ap.add_argument("--model", default=dbt_var("promo_terms_model", "databricks-claude-sonnet-5-5"))
    ap.add_argument("--concurrency", type=int, default=4)
    ap.add_argument("--only", nargs="*", help="draft just these item numbers (a test run)")
    ap.add_argument("--dry-run", action="store_true", help="list the items to draft; no model calls")
    args = ap.parse_args(argv)

    ensure_landing(args.backend)
    version = card_version(args.model)
    month_items, todo = items_needing_cards(args.backend, version)
    if args.only:
        todo = [r for r in todo if r["item_no"] in set(args.only)]
    print(f"{len(todo)} item(s) need a product card ({version}); "
          f"{sum(1 for r in todo if r['_photo'])} with a photo")
    for r in todo:
        print(f"  {r['item_no']} {str(r['promo_description'])[:34]:34s} photo={'yes' if r['_photo'] else 'no'}")
    if args.dry_run or not todo:
        return
    client = get_llm_client(args.backend)
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        cards = [c for c in pool.map(lambda r: draft_one(client, args.model, version, r, month_items), todo) if c]
    spec = LANDING["product_cards"]
    append_records(args.backend, cards, landing_path("product_cards"), spec["dbx"], spec["columns"])
    for c in cards:
        print(f"  {c['item_no']}: {c['brand_on_pack'] or '-'} | {c['flavor_on_pack'] or '-'} | {c['pack'] or '-'}"
              f"\n      search: {c['search_phrases'] or '-'}")
    print(f"drafted {len(cards)} card(s)")


if __name__ == "__main__":
    main()
