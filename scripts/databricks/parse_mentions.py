"""Parse Mentionlytics xlsx -> social.mentions (step ① PARSE).

Databricks **Python-script task** (spark_python_task) — no notebook, no dbutils.
Reads any .xlsx dropped in the landing Volume, normalises the headers, adds
loaded_at / source_file, appends (all-string) to ust_databricks.social.mentions,
and archives the file. Append-only by design: stg_mentionlytics__mentions dedupes
on mention_id (latest loaded_at) downstream, so overlapping weekly drops
self-reconcile.

How to run on Databricks:
  - Task type: Python script (Source: Git, path scripts/databricks/parse_mentions.py)
  - Dependent library (PyPI): openpyxl
  - Runs on a cluster; `spark` is obtained via SparkSession.builder.getOrCreate().
  - Volumes are FUSE-mounted at /Volumes on the driver, so plain os/glob/shutil
    work — no dbutils needed.

The header-normalisation helpers below are kept IDENTICAL to
scripts/convert_mentionlytics.py (the local/DuckDB equivalent). The pure helpers
import without pyspark, so they can be unit-tested locally.

Run order: this -> enrich_mentions.py -> dbt build --select tag:social.
"""

from __future__ import annotations

import glob
import os
import re
import shutil
from datetime import datetime, timezone

import pandas as pd

# ---- Config ----------------------------------------------------------------
CATALOG     = "ust_databricks"
SCHEMA      = "social"
TABLE       = f"{CATALOG}.{SCHEMA}.mentions"
LANDING_DIR = f"/Volumes/{CATALOG}/{SCHEMA}/landing"
ARCHIVE_DIR = f"{LANDING_DIR}/_archive"
SHEET       = "mentions"

EXPECTED_HEADERS = [
    "ID", "Channel", "Category", "Profile", "Profile Visits (Web only)",
    "Profile Users (Web only)", "Language", "Followers/Rank", "Total Engagement",
    "Total Engagement with views", "Likes", "Comments", "Shares", "Views",
    "Impressions", "Date", "Sentiment", "Title", "Content", "Country",
    "Location", "Tracker", "Keyword", "Link",
]


# ---- Prep helpers (mirror scripts/convert_mentionlytics.py) -----------------

def slugify(header: str) -> str:
    """'Profile Visits (Web only)' -> 'profile_visits_web_only'."""
    slug = re.sub(r"[^0-9a-z]+", "_", str(header).strip().lower())
    return slug.strip("_")


def resolve_loaded_at(filename: str, mtime_seconds: float) -> datetime:
    """Export timestamp: a YYYYMMDD / YYYY-MM-DD in the filename, else the file's
    modification time (real time, not midnight — keeps posted_at <= loaded_at so
    the DQ future-date check stays clean)."""
    m = re.search(r"(20\d{2})[-_]?(\d{2})[-_]?(\d{2})", filename)
    if m:
        return datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    return datetime.fromtimestamp(mtime_seconds, tz=timezone.utc).replace(tzinfo=None)


def prep_dataframe(pdf: pd.DataFrame, loaded_at: datetime, source_file: str) -> pd.DataFrame:
    """Normalise headers, add lineage columns, stringify everything (NaN -> None)
    so the append is type-robust — staging casts each column to its real type."""
    missing = [h for h in EXPECTED_HEADERS if h not in pdf.columns]
    if missing:
        print(f"  WARNING expected headers missing: {missing}")
    pdf = pdf.rename(columns={h: slugify(h) for h in pdf.columns})
    pdf = pdf.astype(object).where(pd.notnull(pdf), None)
    for col in pdf.columns:
        pdf[col] = pdf[col].map(lambda v: None if v is None else str(v))
    pdf["loaded_at"] = loaded_at.isoformat(sep=" ")
    pdf["source_file"] = source_file
    return pdf


# ---- Entry point (Databricks) ----------------------------------------------

def main() -> None:
    from pyspark.sql import SparkSession
    spark = SparkSession.builder.getOrCreate()

    files = sorted(glob.glob(os.path.join(LANDING_DIR, "*.xlsx")))
    print(f"{len(files)} xlsx file(s) in {LANDING_DIR}")
    for path in files:
        print(f"  found: {os.path.basename(path)}")

    total = 0
    for path in files:
        name = os.path.basename(path)
        loaded_at = resolve_loaded_at(name, os.path.getmtime(path))
        pdf = prep_dataframe(pd.read_excel(path, sheet_name=SHEET), loaded_at, name)

        (spark.createDataFrame(pdf)
              .write.format("delta").mode("append")
              .option("mergeSchema", "true").saveAsTable(TABLE))
        total += len(pdf)
        print(f"  appended {len(pdf)} rows from {name} (loaded_at={loaded_at.isoformat()})")

        os.makedirs(ARCHIVE_DIR, exist_ok=True)
        shutil.move(path, os.path.join(ARCHIVE_DIR, name))
        print(f"  archived -> {ARCHIVE_DIR}/{name}")

    print(f"DONE. appended {total} rows across {len(files)} file(s).")
    spark.sql(f"""
        select count(*) as raw_rows, count(distinct id) as distinct_ids,
               max(loaded_at) as latest_loaded_at, count(distinct source_file) as files_loaded
        from {TABLE}
    """).show(truncate=False)


if __name__ == "__main__":
    main()
