"""Draft brand / product / flavor and search terms for new promo items (step 2).

NAV has no brand column and promo descriptions are truncated ("COCONUT MILK
DRINK (LESS SUGAR"), so for every promo item WITHOUT a row in
seeds/seed_promo_item_terms.csv the Databricks-hosted LLM drafts:
    brand, product, flavor_variant, pack_format, is_branded
    brand_terms / product_terms / flavor_terms   English + Thai + Vietnamese, native script
    negative_terms                               phrases that mean the brand word is something else
    search_queries                               up to 3 phrases for YouTube / TikTok search
from the promo row plus the NAV catalog (full description, flavor and package
attributes, category) and the WMS item name.

The SEED IS THE SOURCE OF TRUTH. Drafts go to the item_terms_draft landing table
and are used only until a reviewed seed row exists (int_promo_items_enriched.
terms_source = 'draft'). The match step never calls the LLM for terms.

Review loop (local):
    python scripts/draft_promo_terms.py                 # drafts missing items -> item_terms_draft
    python scripts/draft_promo_terms.py --to-seed       # appends those drafts to the seed CSV
    # edit seeds/seed_promo_item_terms.csv, set review_status = reviewed, commit

Reads the dbt models, so run `dbt build --select +int_promo_items_enriched` first.
"""

from __future__ import annotations

import argparse
import csv
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path.cwd() / "scripts"))
try:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
except NameError:
    pass

from promo_common import (  # noqa: E402
    INTERMEDIATE_SCHEMA, LANDING, STAGING_SCHEMA, append_records, dbt_var, ensure_landing, extract_json,
    find_project_root, get_llm_client, landing_path, query, split_terms,
)

PROMPT_VERSION = "v1"
SEED_PATH = "seeds/seed_promo_item_terms.csv"
SEED_COLUMNS = ["item_no", "brand", "product", "flavor_variant", "pack_format", "is_branded",
                "brand_terms", "product_terms", "flavor_terms", "negative_terms",
                "search_queries", "notes", "review_status"]

INSTRUCTIONS = """You prepare search terms so a distributor can find social media posts about the exact products it is promoting. The posts are mostly Thai and Vietnamese, plus English, and some Filipino, Japanese, Korean or Indian.

For the item given, return JSON only:
{
 "brand": "brand name as consumers write it, or null",
 "product": "short English product name without brand or flavor (e.g. 'fruit juice', 'squid snack')",
 "flavor_variant": "flavor/variant that tells this item apart from its siblings, or null if none",
 "pack_format": "can | bottle | bag | box | jar | pouch | frozen | other",
 "is_branded": true/false,
 "brand_terms": ["..."],
 "product_terms": ["..."],
 "flavor_terms": ["..."],
 "negative_terms": ["..."],
 "search_queries": ["..."],
 "notes": "anything a reviewer should check"
}

Rules:
- is_branded is false when there is no searchable consumer brand: generic commodities (sushi mat, peeled cassava, batter mix) and the distributor's private-label frozen dishes (descriptions starting "D FZ", "DFZ" or "D " followed by a dish name). For those, leave every term list empty.
- The promo description is uppercase and truncated; prefer the catalog description. "HB" may be an abbreviation; the catalog description resolves it.
- When the description names no brand, the sibling items from the same manufacturer usually do (e.g. a yogurt juice whose siblings are "DEEDO ... JUICE" is a Deedo product). Use them, and say so in notes.
- brand_terms: the brand in Latin script plus its native-script spelling(s) and common hashtags (e.g. "deedo", "ดีโด้", "#deedo"). Only include spellings that are clearly the brand. Include common misspellings consumers use.
- product_terms: how people write this product type in English, Thai and Vietnamese (e.g. "juice", "น้ำผลไม้", "nước ép"). A hashtag that combines brand and product (e.g. "#tracozy") may appear in both brand_terms and product_terms.
- flavor_variant is a taste or variety (lychee, BBQ cheese, less sugar, original). A size or dimension (22cm, 330ml) is never a flavor.
- flavor_terms: the flavor/variant in English, Thai and Vietnamese (e.g. "lychee", "ลิ้นจี่", "vải"). Empty when flavor_variant is null.
- negative_terms: phrases that show the brand word means something else (a person, film, K-pop group, restaurant, an ordinary word). Empty if the brand is unambiguous.
- search_queries: at most 3 phrases a person would type into YouTube or TikTok to find videos of THIS item, in the language of its home market first (e.g. "trà vải cozy", "deedo cantaloupe"). Empty when is_branded is false.
- Keep every term lowercase except proper nouns in scripts without case. No duplicates."""


def _item_prompt(r: dict) -> str:
    return "\n".join([
        f"item_no: {r.get('item_no')}",
        f"promo description: {r.get('promo_description')}",
        f"promo size: {r.get('promo_size')}",
        f"catalog description: {r.get('item_full_description') or '-'}",
        f"catalog short description: {r.get('nav_description') or '-'}",
        f"catalog body description: {r.get('item_body_description') or '-'}",
        f"catalog flavor attribute: {r.get('attribute_flavor') or '-'}",
        f"catalog package attribute: {r.get('attribute_package') or '-'}",
        f"catalog category / product group: {r.get('item_category_code') or '-'} / {r.get('product_group_code') or '-'}",
        f"country of origin: {r.get('country_of_origin') or '-'}",
        f"warehouse item name: {r.get('wms_item_name') or '-'}",
        f"vendor: {r.get('vendor_no') or '-'}",
        "other catalog items from the same manufacturer (same barcode company prefix): "
        + ("; ".join(r.get("_siblings") or []) or "-"),
    ])


# Barcode company prefix -> sibling products. The promo text often drops the
# brand ("ORANGE FRUIT JUICE WITH YOGURT" is a Deedo juice), but the barcode's
# GS1 company prefix is shared with siblings whose description does name it
# (8850952... = DEEDO CANTALOUPE FRUIT JUICE). 7 digits is a conservative proxy
# for the prefix (real ones run 6-10). A prefix shared by more than
# SIBLING_MAX_GROUP items is a relabeller or the distributor's own prefix
# (UST's 721557... covers hundreds of unrelated items), so it says nothing
# about brand and is skipped.
SIBLING_PREFIX_DIGITS = 7
SIBLING_MAX_GROUP = 40
SIBLING_EXAMPLES = 8


def _upc_prefix(upc) -> str | None:
    digits = "".join(ch for ch in str(upc or "") if ch.isdigit())
    if len(digits) < 12:
        return None
    if len(digits) == 14:          # case-level GTIN-14: drop the packaging indicator
        digits = digits[1:]
    if len(digits) == 12:          # UPC-A -> EAN-13 form, so both share a prefix
        digits = "0" + digits
    return digits[:SIBLING_PREFIX_DIGITS]


def attach_siblings(backend: str, rows: list[dict]) -> None:
    rel = (f"{STAGING_SCHEMA}.stg_nav__items" if backend == "databricks"
           else "ust_staging.stg_nav__items")
    catalog = query(backend, f"select item_no, item_description, upc_code from {rel} "
                             f"where upc_code is not null")
    groups: dict[str, list[tuple[str, str]]] = {}
    for c in catalog:
        p = _upc_prefix(c["upc_code"])
        if p and c.get("item_description"):
            groups.setdefault(p, []).append((c["item_no"], c["item_description"]))
    for r in rows:
        group = groups.get(_upc_prefix(r.get("upc_code")) or "", [])
        if len(group) > SIBLING_MAX_GROUP:
            continue
        r["_siblings"] = [d for n, d in group if n != r["item_no"]][:SIBLING_EXAMPLES]


def items_needing_terms(backend: str) -> list[dict]:
    rel = (f"{INTERMEDIATE_SCHEMA}.int_promo_items_enriched" if backend == "databricks"
           else "ust_intermediate.int_promo_items_enriched")
    rows = query(backend, f"select * from {rel} where terms_source = 'missing'")
    seen, out = set(), []
    for r in rows:                      # one draft per item, however many months list it
        if r["item_no"] not in seen:
            seen.add(r["item_no"])
            out.append(r)
    return out


def _as_list(v) -> list[str]:
    return split_terms(v if isinstance(v, (list, tuple)) else ([] if v is None else str(v).split("|")))


def draft_one(client, model: str, row: dict) -> dict | None:
    # Thai and Vietnamese terms are token-hungry: at 900 tokens a third of the
    # October replies were cut off mid-JSON. One retry rides out a stray reply.
    data, stop = None, None
    for _ in range(2):
        resp = client.messages.create(model=model, max_tokens=2500, system=INSTRUCTIONS,
                                      messages=[{"role": "user", "content": _item_prompt(row)}])
        stop = resp.stop_reason
        data = extract_json("".join(getattr(b, "text", "") for b in resp.content))
        if isinstance(data, dict):
            break
    if not isinstance(data, dict):
        print(f"  ! {row['item_no']}: unparseable reply (stop_reason={stop}), skipped — re-run to retry")
        return None
    branded = bool(data.get("is_branded"))
    return {
        "item_no": row["item_no"],
        "brand": data.get("brand"),
        "product": data.get("product"),
        "flavor_variant": data.get("flavor_variant"),
        "pack_format": data.get("pack_format"),
        "is_branded": "true" if branded else "false",
        "brand_terms": "|".join(_as_list(data.get("brand_terms"))) if branded else None,
        "product_terms": "|".join(_as_list(data.get("product_terms"))) if branded else None,
        "flavor_terms": "|".join(_as_list(data.get("flavor_terms"))) if branded else None,
        "negative_terms": "|".join(_as_list(data.get("negative_terms"))) if branded else None,
        "search_queries": "|".join(_as_list(data.get("search_queries"))[:3]) if branded else None,
        "notes": data.get("notes"),
        "drafted_at": datetime.now(timezone.utc).replace(tzinfo=None).isoformat(sep=" ", timespec="seconds"),
        "model_version": f"{model}/{PROMPT_VERSION}",
    }


def to_seed() -> None:
    """Append every drafted item that has no seed row yet to the seed CSV, as
    review_status = draft. Local only: the seed is a reviewed, committed file."""
    import pandas as pd
    seed_file = find_project_root() / SEED_PATH
    existing = set(pd.read_csv(seed_file, dtype=str)["item_no"]) if seed_file.exists() else set()
    drafts = pd.read_parquet(landing_path("item_terms_draft"))
    drafts = drafts.sort_values("drafted_at").drop_duplicates("item_no", keep="last")
    new = drafts[~drafts["item_no"].isin(existing)]
    if new.empty:
        print("nothing to add — every drafted item already has a seed row")
        return
    write_header = not seed_file.exists() or seed_file.stat().st_size == 0
    with open(seed_file, "a", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=SEED_COLUMNS, extrasaction="ignore")
        if write_header:
            w.writeheader()
        for rec in new.to_dict("records"):
            rec["review_status"] = "draft"
            w.writerow({k: ("" if rec.get(k) is None else rec.get(k)) for k in SEED_COLUMNS})
    print(f"appended {len(new)} draft row(s) to {SEED_PATH} — review, set review_status, commit")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--backend", choices=["local", "databricks"], default="local")
    ap.add_argument("--to-seed", action="store_true", help="append drafts to the seed CSV (local)")
    ap.add_argument("--model", default=dbt_var("promo_terms_model", "databricks-claude-sonnet-5-5"))
    ap.add_argument("--concurrency", type=int, default=6)
    args = ap.parse_args(argv)

    if args.to_seed:
        to_seed()
        return
    ensure_landing(args.backend)
    rows = items_needing_terms(args.backend)
    attach_siblings(args.backend, rows)
    print(f"{len(rows)} promo item(s) with no seed row and no draft")
    if not rows:
        return
    client = get_llm_client(args.backend)
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        drafts = [d for d in pool.map(lambda r: draft_one(client, args.model, r), rows) if d]
    append_records(args.backend, drafts, landing_path("item_terms_draft"),
                   LANDING["item_terms_draft"]["dbx"], LANDING["item_terms_draft"]["columns"])
    for d in drafts:
        print(f"  {d['item_no']}: {d['brand'] or '-'} | {d['product'] or '-'} | "
              f"{d['flavor_variant'] or '-'} | branded={d['is_branded']}")
    print(f"drafted {len(drafts)} item(s)")


if __name__ == "__main__":
    main()
