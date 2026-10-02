"""Match promo items against ALL social listening posts (step 3).

Two passes, because neither alone is good enough:

  1. KEYWORDS (recall, cheap). Every branded promo item's reviewed terms are run
     over the raw title + content of every Mentionlytics post (stg_mentionlytics__
     mentions — the deduped raw posts, NOT the enrichment tags, which are too
     generic and lose the post's wording). A post is a candidate when it names the
     brand AND the product or flavor; see promo_common.ItemTerms. On the October
     corpus this turns 34 items x 53k posts into a few hundred pairs.

  2. AI JUDGE (precision). The Databricks-hosted model reads each candidate's full
     text and returns exact / close / reject with a reason — this is where "cozy"
     the adjective, Sting the singer and Hoshi the K-pop idol get thrown out. The
     judge can lower the keyword level but never raise it: an Exact row always has
     brand, product and (when the item has one) flavor hits in its text.

Every judged pair is stored, rejects included, so a rerun only judges new posts
(or every post again after a JUDGE_PROMPT_VERSION bump). A pair whose judge call
fails is NOT stored and is retried next run, rather than shipping a guess.

    python scripts/match_promo_social.py --dry-run      # keyword pass only, no LLM
    python scripts/match_promo_social.py                # judge new candidates
    python scripts/match_promo_social.py --backend databricks

Reads dbt models, so run `dbt build --select +int_promo_items_enriched
+stg_mentionlytics__mentions` first. Local runs sign in to Databricks through the
browser for the model (see promo_common._bearer_token).
"""

from __future__ import annotations

import argparse
import sys
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path.cwd() / "scripts"))
try:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
except NameError:
    pass

from promo_common import (  # noqa: E402
    INTERMEDIATE_SCHEMA, JUDGE_PROMPT_VERSION, LANDING, STAGING_SCHEMA, ItemTerms,
    append_records, dbt_var, ensure_landing, get_llm_client, judge_majority, landing_path,
    match_text, query, read_local_parquet,
)

ITEM_FIELDS = ["item_no", "promo_description", "item_full_description", "brand", "product",
               "flavor_variant", "pack_format", "brand_terms", "product_terms", "flavor_terms",
               "negative_terms"]


def _rel(backend, schema_dbx, schema_local, name):
    return f"{schema_dbx}.{name}" if backend == "databricks" else f"{schema_local}.{name}"


def read_items(backend) -> list[dict]:
    rel = _rel(backend, INTERMEDIATE_SCHEMA, "ust_intermediate", "int_promo_items_enriched")
    rows = query(backend, f"select {', '.join(ITEM_FIELDS)} from {rel} "
                          f"where is_branded and brand_terms is not null")
    seen, out = set(), []
    for r in rows:                  # terms are per item, not per month
        if r["item_no"] not in seen:
            seen.add(r["item_no"])
            out.append(r)
    attach_brand_siblings(out)
    return out


def attach_brand_siblings(items: list[dict]) -> None:
    """Give each item the same brand's OTHER promo items, so the judge can tell
    "Deedo yogurt juice" is a different item from "Deedo cantaloupe juice"
    rather than the same product line with an unstated flavor."""
    by_brand: dict[str, list[dict]] = {}
    for it in items:
        if it.get("brand"):
            by_brand.setdefault(it["brand"].strip().casefold(), []).append(it)
    for it in items:
        group = by_brand.get((it.get("brand") or "").strip().casefold(), [])
        it["_siblings"] = sorted({
            " ".join(x for x in (o.get("brand"), o.get("product"), o.get("flavor_variant")) if x)
            + f" ({o['promo_description']})"
            for o in group if o["item_no"] != it["item_no"]
        })


def read_mentions(backend) -> list[dict]:
    rel = _rel(backend, STAGING_SCHEMA, "ust_staging", "stg_mentionlytics__mentions")
    return query(backend, f"select mention_id, channel, title, content from {rel}")


def read_judged(backend) -> set[tuple[str, int]]:
    """(item_no, mention_id) pairs already judged at the current judge version."""
    spec = LANDING["social_judgments"]
    if backend == "databricks":
        rows = query(backend, f"select item_no, mention_id from {spec['dbx']} "
                              f"where judge_version = '{JUDGE_PROMPT_VERSION}'")
    else:
        rows = [r for r in read_local_parquet(landing_path("social_judgments"))
                if r.get("judge_version") == JUDGE_PROMPT_VERSION]
    return {(str(r["item_no"]), int(r["mention_id"])) for r in rows if r.get("mention_id") is not None}


def _brand_tokens(terms: ItemTerms) -> tuple[str, ...]:
    """The item's brand terms as plain strings. A whole-word regex hit always
    contains its term as a substring, so `token in text` is a safe prefilter —
    and a fast one: on the October corpus a single regex alternation over every
    brand took 299 s, substring checks well under a second."""
    return tuple(token for token, _, _ in terms.brand)


def keyword_candidates(items: list[dict], mentions: list[dict]) -> list[dict]:
    compiled = []
    for it in items:
        t = ItemTerms(it["brand_terms"], it["product_terms"], it["flavor_terms"], it["negative_terms"])
        tokens = _brand_tokens(t)
        if tokens:
            compiled.append((it, t, tokens))
    all_tokens = tuple({tok for _, _, toks in compiled for tok in toks})
    out = []
    for m in mentions:
        text = match_text(m.get("title"), m.get("content"))
        # almost no post names any promo brand: skip it before any per-item work
        if not any(tok in text for tok in all_tokens):
            continue
        for it, t, tokens in compiled:
            if not any(tok in text for tok in tokens):
                continue
            ev = t.classify(text)
            if ev["keyword_level"]:
                out.append({"item": it, "mention": m, "evidence": ev, "match_text": text})
    return out


def judge_candidates(client, model, cands, concurrency, votes=3):
    now = lambda: datetime.now(timezone.utc).replace(tzinfo=None).isoformat(sep=" ", timespec="seconds")

    def one(c):
        m = c["mention"]
        post = {"channel": m.get("channel"),
                "text": " ".join(str(x) for x in (m.get("title"), m.get("content")) if x)}
        try:
            v = judge_majority(client, model, c["item"], post, c["evidence"], votes)
        except Exception as e:                       # left unjudged -> retried next run
            print(f"  ! judge failed for {c['item']['item_no']} / {m['mention_id']}: {str(e)[:120]}")
            return None
        if v is None:
            return None
        ev = c["evidence"]
        return {"item_no": c["item"]["item_no"], "mention_id": m["mention_id"],
                "keyword_level": ev["keyword_level"], "brand_hit": ev["brand_hit"],
                "product_hit": ev["product_hit"], "flavor_hit": ev["flavor_hit"],
                "match_text": c["match_text"], "verdict": v["verdict"], "judge_votes": v["votes"],
                "matched_content_item": v["matched_content_item"], "reason": v["reason"],
                "judge_model": model, "judge_version": JUDGE_PROMPT_VERSION, "judged_at": now()}

    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        return [r for r in pool.map(one, cands) if r]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--backend", choices=["local", "databricks"], default="local")
    ap.add_argument("--dry-run", action="store_true", help="keyword pass only; print candidates, no LLM")
    ap.add_argument("--model", default=dbt_var("promo_judge_model", "databricks-claude-sonnet-5-5"))
    ap.add_argument("--votes", type=int, default=int(dbt_var("promo_judge_votes", 3)))
    ap.add_argument("--concurrency", type=int, default=8)
    ap.add_argument("--limit", type=int, help="judge at most this many new candidates")
    args = ap.parse_args(argv)

    ensure_landing(args.backend)
    t0 = time.time()
    items, mentions = read_items(args.backend), read_mentions(args.backend)
    cands = keyword_candidates(items, mentions)
    print(f"{len(items)} searchable items x {len(mentions):,} posts -> {len(cands)} keyword "
          f"candidates in {time.time() - t0:.0f}s")
    by_item = Counter((c["item"]["item_no"], c["evidence"]["keyword_level"]) for c in cands)
    for it in items:
        e, c = by_item.get((it["item_no"], "exact"), 0), by_item.get((it["item_no"], "close"), 0)
        if e or c:
            print(f"  {it['item_no']} {it['promo_description'][:32]:32s} exact {e:4d}  close {c:4d}")

    judged = read_judged(args.backend)
    new = [c for c in cands if (str(c["item"]["item_no"]), int(c["mention"]["mention_id"])) not in judged]
    if args.limit:
        new = new[: args.limit]
    print(f"{len(cands) - len(new)} already judged at {JUDGE_PROMPT_VERSION}; {len(new)} to judge")
    if args.dry_run or not new:
        return
    records = judge_candidates(get_llm_client(args.backend), args.model, new, args.concurrency, args.votes)
    spec = LANDING["social_judgments"]
    append_records(args.backend, records, landing_path("social_judgments"), spec["dbx"], spec["columns"])
    tally = Counter(r["verdict"] for r in records)
    print(f"judged {len(records)} of {len(new)} with {args.model}: "
          + ", ".join(f"{k} {v}" for k, v in sorted(tally.items())))


if __name__ == "__main__":
    main()
