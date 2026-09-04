"""Measure whether batching the enrichment calls contaminates labels.

scripts/enrich_mentions.py sends MENTIONS_PER_CALL mentions in one LLM call. That
cuts calls ~10x, and it introduces one risk that no amount of validation can catch:
LABEL BLEED — the model reads mention A while mention B sits in the same context, and
tags A with something only B mentioned. The id comes back correct, so nothing looks
wrong; the label is just wrong.

(The OTHER failure mode — labels attached to the wrong id, or ids dropped/invented —
is structurally handled in enrich_mentions.classify_call: ids are validated against
exactly what was sent and unmatched mentions are retried alone. That one needs no
measurement. This script is only about contaminated reading.)

THE EXPERIMENT, and why it has three passes rather than two. A naive
batched-vs-single comparison can't distinguish bleed from the model's own run-to-run
variance: enrich_mentions doesn't pin temperature, so labelling the same mention
twice one-at-a-time already disagrees somewhat. So:

    pass A   one mention per call          <- baseline
    pass B   one mention per call          <- same settings, again: the NOISE FLOOR
    pass C   MENTIONS_PER_CALL per call    <- the thing under test

A-vs-B is what disagreement looks like with no batching involved at all. A-vs-C is
what disagreement looks like with batching. Bleed shows up as C diverging MORE than
B does — and specifically as EXTRA labels in C, because contamination adds labels
borrowed from neighbours rather than removing the real ones. Hence extra and missing
are reported separately; the asymmetry is the signal.

Reads mentions and calls the model. WRITES NOTHING — it never touches
social.mention_enrichment, so it is safe to run against prod at any time.

    python scripts/check_batch_bleed.py --backend databricks
    python scripts/check_batch_bleed.py --backend local --sample 40 --per-call 5

Re-run it after changing MENTIONS_PER_CALL or the INSTRUCTIONS block. Cost is
~2 x sample + sample/per_call calls (default: ~210).
"""

from __future__ import annotations

import argparse
import sys
from collections import defaultdict

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))

import enrich_mentions as E

ARRAY_FIELDS = ["mentioned_dishes", "mentioned_products", "ingredients",
                "themes", "brands", "subject_dishes", "subject_products"]
SCALAR_FIELDS = ["is_food_relevant", "is_spam", "sentiment_normalized"]


def read_sample(backend, duckdb_path, n):
    """The most recent `n` mentions that would actually reach the model: content to
    read, and not caught by the deterministic spam pre-filter."""
    cols = E._MENTION_COLS
    sql = (f"select {cols} from {{rel}} "
           f"where posted_at is not null "
           f"  and (content is not null or title is not null) "
           f"order by posted_at desc limit {int(n) * 2}")
    if backend == "databricks":
        spark = E._get_spark()
        rows = [r.asDict() for r in spark.sql(sql.format(rel=E.DBX_MENTIONS_REL)).collect()]
    else:
        import duckdb
        con = duckdb.connect(duckdb_path, read_only=True)
        rows = con.sql(sql.format(rel=E.DUCKDB_MENTIONS_REL)).df().to_dict("records")
        con.close()
    return [m for m in rows if not E.is_prefilter_spam(m)][:int(n)]


def _norm_set(v):
    """Labels compared case/space-insensitively — "Fish Sauce" vs "fish sauce" is not
    a disagreement worth counting."""
    return {str(x).strip().lower() for x in (v or []) if str(x).strip()}


def compare(left, right, ids):
    """Per-field agreement between two label passes over the same mentions."""
    out = {}
    for f in ARRAY_FIELDS:
        jac, extra, missing = [], 0, 0
        for mid in ids:
            a, b = _norm_set(left[mid].get(f)), _norm_set(right[mid].get(f))
            union = a | b
            jac.append(1.0 if not union else len(a & b) / len(union))
            extra += len(b - a)        # in RIGHT but not LEFT
            missing += len(a - b)      # in LEFT but not RIGHT
        out[f] = {"jaccard": sum(jac) / len(jac) if jac else 1.0,
                  "extra": extra, "missing": missing}
    for f in SCALAR_FIELDS:
        same = sum(1 for mid in ids if left[mid].get(f) == right[mid].get(f))
        out[f] = {"agree": same / len(ids) if ids else 1.0}
    return out


def _table(title, cmp_noise, cmp_batch):
    print(f"\n{title}")
    print(f"  {'field':<20} {'single vs single':>18} {'batched vs single':>19}   verdict")
    print(f"  {'-'*20} {'-'*18} {'-'*19}   {'-'*7}")
    for f in ARRAY_FIELDS:
        n, b = cmp_noise[f], cmp_batch[f]
        # batching is clean when it disagrees no more than two single passes do
        verdict = "ok" if b["jaccard"] >= n["jaccard"] - 0.05 else "SUSPECT"
        print(f"  {f:<20} {n['jaccard']:>17.1%} {b['jaccard']:>18.1%}   {verdict}")
        print(f"  {'':<20} {'+' + str(n['extra']) + ' / -' + str(n['missing']):>17} "
              f"{'+' + str(b['extra']) + ' / -' + str(b['missing']):>18}   labels added/dropped")
    for f in SCALAR_FIELDS:
        n, b = cmp_noise[f], cmp_batch[f]
        verdict = "ok" if b["agree"] >= n["agree"] - 0.05 else "SUSPECT"
        print(f"  {f:<20} {n['agree']:>17.1%} {b['agree']:>18.1%}   {verdict}")


def main(backend="local", duckdb_path=E.LOCAL_DUCKDB_PATH, sample=100,
         per_call=None, concurrency=None):
    per_call = E.MENTIONS_PER_CALL if per_call is None else int(per_call)
    concurrency = E.CONCURRENCY if concurrency is None else int(concurrency)
    if per_call < 2:
        raise SystemExit("--per-call must be 2+ — there is nothing to test at 1.")

    mentions = read_sample(backend, duckdb_path, sample)
    if not mentions:
        raise SystemExit("no mentions to sample.")
    print(f"sample: {len(mentions)} mentions | prompt {E.PROMPT_VERSION} | "
          f"testing {per_call} per call vs 1 per call")

    client = E.get_client(backend)
    print("pass A: one per call ...")
    a = E.classify_batch(client, mentions, concurrency, per_call=1)
    print("pass B: one per call again (noise floor) ...")
    b = E.classify_batch(client, mentions, concurrency, per_call=1)
    print(f"pass C: {per_call} per call ...")
    c = E.classify_batch(client, mentions, concurrency, per_call=per_call)

    ids = sorted(set(a) & set(b) & set(c))
    print(f"\n{len(ids)}/{len(mentions)} mentions labelled by all three passes")
    if not ids:
        raise SystemExit("no overlap — check the serving endpoint.")

    cmp_noise = compare(a, b, ids)
    cmp_batch = compare(a, c, ids)
    _table("AGREEMENT (higher = more consistent)", cmp_noise, cmp_batch)

    # the headline: bleed is EXTRA labels, above what plain re-running produces
    tot_extra_noise = sum(cmp_noise[f]["extra"] for f in ARRAY_FIELDS)
    tot_extra_batch = sum(cmp_batch[f]["extra"] for f in ARRAY_FIELDS)
    print(f"\nextra labels vs pass A: {tot_extra_noise} when re-run single, "
          f"{tot_extra_batch} when batched")
    if tot_extra_batch > tot_extra_noise * 1.5 + 5:
        print(f"=> BATCHING IS ADDING LABELS beyond run-to-run variance. Likely bleed: "
              f"lower MENTIONS_PER_CALL and re-run this check.")
    else:
        print(f"=> batching adds no more than re-running does. {per_call} per call "
              f"looks safe at prompt {E.PROMPT_VERSION}.")

    worst = sorted(ids, key=lambda mid: sum(
        len(_norm_set(c[mid].get(f)) - _norm_set(a[mid].get(f))) for f in ARRAY_FIELDS),
        reverse=True)[:3]
    print("\nmost divergent mentions (inspect these by hand):")
    for mid in worst:
        print(f"  {mid}")
        for f in ARRAY_FIELDS:
            sa, sc = _norm_set(a[mid].get(f)), _norm_set(c[mid].get(f))
            if sa != sc:
                print(f"    {f}: single={sorted(sa)} batched={sorted(sc)}")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--backend", choices=["local", "databricks"], default="local")
    p.add_argument("--duckdb", default=E.LOCAL_DUCKDB_PATH)
    p.add_argument("--sample", type=int, default=100, help="mentions to test (default 100)")
    p.add_argument("--per-call", type=int, default=None,
                   help=f"batch size under test (default {E.MENTIONS_PER_CALL})")
    p.add_argument("--concurrency", type=int, default=None)
    args = p.parse_args()
    try:
        sys.stdout.reconfigure(encoding="utf-8")   # Thai / Vietnamese labels
    except Exception:
        pass
    main(backend=args.backend, duckdb_path=args.duckdb, sample=args.sample,
         per_call=args.per_call, concurrency=args.concurrency)
