"""Export mart_social_trending_items to an .xlsx for the marketing team (step ⑤).

The final step of the weekly social job. Reads the dbt-built mart, keeps ONE week
(the latest by default), flattens the array columns to plain text (Excel can't
show an array cell), renames columns to friendly headers, and writes a single
sheet sorted by trend_rank.

This is the ONLY consumer that flattens the arrays — the mart keeps them as arrays
for Genie/BI. dbt stays the source of truth; this is a thin presentation layer.

  --backend local       reads the local duckdb build (dev.duckdb)
  --backend databricks  reads ust_databricks.ust_reporting.mart_social_trending_items

  --period YYYY-MM-DD   which week (period_start, Monday); default = latest present
  --out PATH            output .xlsx (default exports/social_trending_items_<week>.xlsx)

    python scripts/export_trending_items_xlsx.py --backend local
    python scripts/export_trending_items_xlsx.py --backend databricks --period 2026-07-27
"""

from __future__ import annotations

import argparse
import os
import sys

LOCAL_DUCKDB_PATH = "dev.duckdb"
DUCKDB_MART_REL = "ust_reporting.mart_social_trending_items"
DBX_MART_TABLE = "ust_databricks.ust_reporting.mart_social_trending_items"

# mart column -> friendly header, in export order. Arrays are flattened first.
COLUMN_MAP = [
    ("trend_rank",          "Rank"),
    ("concept_label",       "Trending Item"),
    ("concept_type",        "Type"),
    ("mention_count",       "Mentions"),
    ("net_sentiment",       "Net Sentiment"),
    ("result_type",         "Do We Carry It?"),
    ("matched_item_name",   "Our Item"),
    ("matched_prtnum",      "Our Part #"),
    ("in_stock_label",      "In Stock?"),
    ("shippable_qty",       "Shippable Qty"),
    ("recommended_display", "Recommended Items"),
    ("links_display",       "Source Links"),
    ("action_signal",       "Action"),
]


def load_mart(backend, duckdb_path):
    """Return the whole mart as a pandas DataFrame."""
    if backend == "databricks":
        spark = _get_spark()
        return spark.sql(f"select * from {DBX_MART_TABLE}").toPandas()
    import duckdb
    con = duckdb.connect(duckdb_path, read_only=True)
    df = con.sql(f"select * from {DUCKDB_MART_REL}").df()
    con.close()
    return df


def _get_spark():
    try:
        return spark  # noqa: F821
    except NameError:
        from pyspark.sql import SparkSession
        return SparkSession.builder.getOrCreate()


def _as_list(v):
    """Normalise an array cell (numpy array / list / None) to a Python list."""
    if v is None:
        return []
    try:
        return [x for x in list(v) if x is not None and str(x).strip() != ""]
    except TypeError:
        return []


def flatten(df):
    """Add the presentation columns the workbook uses (arrays -> text, labels)."""
    df = df.copy()
    names = df["recommended_items"].apply(_as_list)
    prtnums = df["recommended_prtnums"].apply(_as_list)

    def pair(nm, pn):
        out = []
        for i, n in enumerate(nm):
            p = pn[i] if i < len(pn) else None
            out.append(f"{n} ({p})" if p else str(n))
        return "; ".join(out)

    df["recommended_display"] = [pair(n, p) for n, p in zip(names, prtnums)]
    df["links_display"] = df["source_links"].apply(lambda v: "\n".join(_as_list(v)))
    df["in_stock_label"] = df["in_stock"].map(
        lambda x: "Yes" if x == 1 else ("No" if x == 0 else "")
    )
    return df


def pick_week(df, period):
    if period:
        return df[df["period_start"].astype(str) == period], period
    if df.empty:
        return df, None
    latest = df["period_start"].astype(str).max()
    return df[df["period_start"].astype(str) == latest], latest


def main(backend="local", period=None, out=None, duckdb_path=LOCAL_DUCKDB_PATH):
    df = load_mart(backend, duckdb_path)
    df, period = pick_week(df, period)
    if df.empty:
        print(f"No rows"
              + (f" for period={period}" if period else "") + ". Nothing exported.")
        return

    df = flatten(df).sort_values("trend_rank")
    export = df[[src for src, _ in COLUMN_MAP]].rename(columns=dict(COLUMN_MAP))

    out = out or os.path.join("exports", f"social_trending_items_{period}.xlsx")
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    export.to_excel(out, sheet_name=f"Trending {period}", index=False)

    print(f"Exported {len(export)} rows -> {out}  (week {period})")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--backend", choices=["local", "databricks"], default="local")
    p.add_argument("--period", help="week period_start (YYYY-MM-DD, Monday); default = latest present")
    p.add_argument("--out", help="output .xlsx path")
    p.add_argument("--duckdb", default=LOCAL_DUCKDB_PATH)
    args = p.parse_args()
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    main(backend=args.backend, period=args.period, out=args.out, duckdb_path=args.duckdb)
