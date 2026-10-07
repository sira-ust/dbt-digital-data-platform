"""One-time upload of a month's locally-produced promo results to Databricks.

October 2026 was matched on a laptop (DuckDB) before the Databricks job existed: the
promo list, the AI judge's verdicts, the YouTube search results and the drafted terms
all sit in data/real/promo/. Uploading them lets the job's first run find that month
done — every step skips work already in its landing table (judged pairs at the
current JUDGE_PROMPT_VERSION, items already searched that month, items with terms) —
so it spends no YouTube quota and judges only posts newer than the local run.

Writes through the SQL warehouse (the laptop has no Spark), into the same all-string
landing tables the scripts write, creating any that do not exist yet. Idempotent: a
row whose key is already in the table is not written again, and a promo month already
loaded is skipped, so a second run uploads nothing.

    promo_items             one month's list, skipped if that month is already loaded
    promo_social_judgments  only rows at the current judge version (older drafts are
                            superseded), keyed by (item_no, mention_id, judge_version)
    promo_youtube_videos    keyed by (promo_month, item_no, video_id, search_query);
                            promo_month is written as YYYY-MM-DD, the value the job's
                            cache check compares against
    promo_item_terms_draft  keyed by (item_no, model_version)

    python scripts/bootstrap_promo_results.py --from data/real/promo --month 2026-10           # dry run
    python scripts/bootstrap_promo_results.py --from data/real/promo --month 2026-10 --confirm

Auth: DATABRICKS_TOKEN (the SQL-warehouse PAT is enough — no files or secrets API).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from promo_common import JUDGE_PROMPT_VERSION, LANDING, SOCIAL_SCHEMA  # noqa: E402

HOST = os.environ.get("DATABRICKS_HOST", "adb-7405618436278207.7.azuredatabricks.net") \
    .replace("https://", "").rstrip("/")
HTTP_PATH = "/sql/1.0/warehouses/e165fed86011619a"
ITEMS_TABLE = f"{SOCIAL_SCHEMA}.promo_items"
BATCH = 200


def _str(v):
    if v is None:
        return None
    try:
        import math
        if isinstance(v, float) and math.isnan(v):
            return None
    except Exception:
        pass
    return str(v)


def _rows(df, columns: list[str]) -> list[dict]:
    return [{c: _str(r.get(c)) for c in columns} for r in df.to_dict("records")]


def _ensure_table(cur, table: str, columns: list[str]) -> None:
    cols = ", ".join(f"`{c}` string" for c in columns)
    cur.execute(f"create table if not exists {table} ({cols}) using delta")
    cur.execute(f"describe table {table}")
    have = {r[0] for r in cur.fetchall()}
    missing = [c for c in columns if c not in have]
    if missing:
        cur.execute(f"alter table {table} add columns (" + ", ".join(f"`{c}` string" for c in missing) + ")")


def _existing(cur, table: str, key: list[str]) -> set[tuple]:
    try:
        cur.execute(f"select distinct {', '.join(f'`{k}`' for k in key)} from {table}")
    except Exception:            # the table does not exist yet
        return set()
    return {tuple(None if v is None else str(v) for v in r) for r in cur.fetchall()}


def _insert(cur, table: str, columns: list[str], rows: list[dict]) -> None:
    """Rows go up as ONE JSON parameter per batch and are unpacked server-side, so a
    long YouTube description needs no quoting and a batch needs no per-value params."""
    struct = ", ".join(f"`{c}`: string" for c in columns)
    cols = ", ".join(f"`{c}`" for c in columns)
    for i in range(0, len(rows), BATCH):
        cur.execute(
            f"insert into {table} ({cols}) "
            f"select {cols} from (select inline(from_json(:payload, 'array<struct<{struct}>>')))",
            {"payload": json.dumps(rows[i:i + BATCH], ensure_ascii=False)})


def plan(src: Path, month: str, cur) -> list[tuple[str, list[str], list[dict], int]]:
    """-> [(table, columns, rows to write, rows in the file)]"""
    import pandas as pd
    out = []

    items = pd.read_parquet(src / f"promo_items_{month.replace('-', '')}.parquet")
    item_cols = list(items.columns)
    loaded = {k[0][:7] for k in _existing(cur, ITEMS_TABLE, ["promo_month"]) if k[0]}
    out.append((ITEMS_TABLE, item_cols, [] if month in loaded else _rows(items, item_cols), len(items)))

    spec = LANDING["social_judgments"]
    j = pd.read_parquet(src / spec["file"])
    j = j[j["judge_version"] == JUDGE_PROMPT_VERSION]
    have = _existing(cur, spec["dbx"], ["item_no", "mention_id", "judge_version"])
    rows = [r for r in _rows(j, spec["columns"]) if (r["item_no"], r["mention_id"], r["judge_version"]) not in have]
    out.append((spec["dbx"], spec["columns"], rows, len(j)))

    spec = LANDING["youtube_videos"]
    y = pd.read_parquet(src / spec["file"])
    y["promo_month"] = y["promo_month"].astype(str).str[:10]
    have = _existing(cur, spec["dbx"], ["promo_month", "item_no", "video_id", "search_query"])
    rows = [r for r in _rows(y, spec["columns"])
            if (r["promo_month"], r["item_no"], r["video_id"], r["search_query"]) not in have]
    out.append((spec["dbx"], spec["columns"], rows, len(y)))

    spec = LANDING["item_terms_draft"]
    d = pd.read_parquet(src / spec["file"])
    have = _existing(cur, spec["dbx"], ["item_no", "model_version"])
    rows = [r for r in _rows(d, spec["columns"]) if (r["item_no"], r["model_version"]) not in have]
    out.append((spec["dbx"], spec["columns"], rows, len(d)))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--from", dest="src", required=True, help="folder holding the month's parquet files")
    ap.add_argument("--month", required=True, help="the promo month, YYYY-MM")
    ap.add_argument("--confirm", action="store_true", help="write; without it, only report what would be written")
    args = ap.parse_args(argv)

    from databricks import sql
    with sql.connect(server_hostname=HOST, http_path=HTTP_PATH,
                     access_token=os.environ["DATABRICKS_TOKEN"]) as conn, conn.cursor() as cur:
        steps = plan(Path(args.src), args.month, cur)
        for table, _, rows, total in steps:
            print(f"  {table:45s} {len(rows):5,} of {total:5,} rows to write")
        if not args.confirm:
            print("dry run — nothing written; add --confirm to upload")
            return
        for table, columns, rows, _ in steps:
            _ensure_table(cur, table, columns)
            if rows:
                _insert(cur, table, columns, rows)
        print("uploaded. Re-run without --confirm: every count should now be 0.")


if __name__ == "__main__":
    main()
