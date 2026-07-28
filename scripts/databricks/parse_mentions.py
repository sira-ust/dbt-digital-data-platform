# Databricks notebook source
# MAGIC %md
# MAGIC # Parse Mentionlytics xlsx → social.mentions (step ① PARSE)
# MAGIC
# MAGIC Reads any `.xlsx` dropped into the landing Volume, normalises the headers,
# MAGIC adds `loaded_at` / `source_file`, and **appends** to the Delta table
# MAGIC `ust_databricks.social.mentions`. Processed files are moved to an `_archive`
# MAGIC subfolder so re-running is safe.
# MAGIC
# MAGIC Append-only by design: `stg_mentionlytics__mentions` dedupes on `mention_id`
# MAGIC (latest `loaded_at` wins), so overlapping weekly drops self-reconcile.
# MAGIC
# MAGIC **Run order:** this notebook → `enrich_mentions.py` → `dbt build`.
# MAGIC
# MAGIC > The header-normalisation logic below is kept IDENTICAL to
# MAGIC > `scripts/convert_mentionlytics.py` (the local/DuckDB equivalent). If you
# MAGIC > adopt Databricks Git folders, replace the inlined helpers with an import
# MAGIC > of a shared module so there is one parser.

# COMMAND ----------

# MAGIC %pip install openpyxl
# MAGIC dbutils.library.restartPython()

# COMMAND ----------

import re
from datetime import datetime, timezone

import pandas as pd

# ---- Config ----------------------------------------------------------------
CATALOG       = "ust_databricks"
SCHEMA        = "social"
TABLE         = f"{CATALOG}.{SCHEMA}.mentions"
LANDING_DIR   = f"/Volumes/{CATALOG}/{SCHEMA}/landing"
ARCHIVE_DIR   = f"{LANDING_DIR}/_archive"
SHEET         = "mentions"

# The 24 raw headers (export order) for a presence check. Unexpected headers are
# still carried through (slugified) so a Mentionlytics tweak doesn't drop data.
EXPECTED_HEADERS = [
    "ID", "Channel", "Category", "Profile", "Profile Visits (Web only)",
    "Profile Users (Web only)", "Language", "Followers/Rank", "Total Engagement",
    "Total Engagement with views", "Likes", "Comments", "Shares", "Views",
    "Impressions", "Date", "Sentiment", "Title", "Content", "Country",
    "Location", "Tracker", "Keyword", "Link",
]

# COMMAND ----------

# ---- Prep helpers (mirror scripts/convert_mentionlytics.py) -----------------

def slugify(header: str) -> str:
    """Lowercase; any run of non-alphanumerics -> a single underscore.
    'Profile Visits (Web only)' -> 'profile_visits_web_only'
    'Followers/Rank'            -> 'followers_rank'
    """
    slug = re.sub(r"[^0-9a-z]+", "_", str(header).strip().lower())
    return slug.strip("_")


def resolve_loaded_at(filename: str, modification_time_ms: int) -> datetime:
    """Export timestamp: a YYYYMMDD / YYYY-MM-DD in the filename, else the file's
    upload/modification time. (No midnight-date default — using the real upload
    time keeps posted_at <= loaded_at, so the DQ future-date check stays clean.)
    """
    m = re.search(r"(20\d{2})[-_]?(\d{2})[-_]?(\d{2})", filename)
    if m:
        return datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    return datetime.fromtimestamp(modification_time_ms / 1000, tz=timezone.utc).replace(tzinfo=None)


def prep_dataframe(pdf: pd.DataFrame, loaded_at: datetime, source_file: str) -> pd.DataFrame:
    """Normalise headers, add lineage columns, and stringify everything so the
    append is type-robust — staging casts each column to its real type (same
    contract as the mysql source). NaN -> None."""
    missing = [h for h in EXPECTED_HEADERS if h not in pdf.columns]
    if missing:
        print(f"  WARNING expected headers missing: {missing}")

    pdf = pdf.rename(columns={h: slugify(h) for h in pdf.columns})
    pdf = pdf.astype(object).where(pd.notnull(pdf), None)   # NaN -> None
    for col in pdf.columns:
        pdf[col] = pdf[col].map(lambda v: None if v is None else str(v))
    pdf["loaded_at"] = loaded_at.isoformat(sep=" ")
    pdf["source_file"] = source_file
    return pdf

# COMMAND ----------

# ---- Find new files in the landing Volume ----------------------------------

def list_xlsx(path: str):
    try:
        entries = dbutils.fs.ls(path)
    except Exception as e:
        print(f"cannot list {path}: {e}")
        return []
    return [f for f in entries if not f.isDir() and f.name.lower().endswith(".xlsx")]

files = list_xlsx(LANDING_DIR)
print(f"{len(files)} xlsx file(s) in landing:")
for f in files:
    print(f"  {f.name}")

# COMMAND ----------

# ---- Parse each file and append to the Delta table --------------------------

total_appended = 0
for f in files:
    # pandas reads the Volume path directly (Volumes are FUSE-mounted on the driver)
    local_path = f.path.replace("dbfs:", "")          # /Volumes/... for pandas
    loaded_at = resolve_loaded_at(f.name, f.modificationTime)
    print(f"parsing {f.name}  (loaded_at={loaded_at.isoformat()})")

    pdf = pd.read_excel(local_path, sheet_name=SHEET)
    pdf = prep_dataframe(pdf, loaded_at, f.name)

    sdf = spark.createDataFrame(pdf)                   # all-string columns
    (sdf.write.format("delta").mode("append")
        .option("mergeSchema", "true").saveAsTable(TABLE))

    total_appended += pdf.shape[0]
    print(f"  appended {pdf.shape[0]} rows")

    # archive so a re-run doesn't reprocess it
    dbutils.fs.mkdirs(ARCHIVE_DIR)
    dbutils.fs.mv(f.path, f"{ARCHIVE_DIR}/{f.name}")
    print(f"  archived -> {ARCHIVE_DIR}/{f.name}")

print(f"\nDONE. appended {total_appended} rows across {len(files)} file(s).")

# COMMAND ----------

# ---- Verify ----------------------------------------------------------------
# Raw row count (pre-dedupe) and distinct mentions. Staging dedupes on id.
display(spark.sql(f"""
    select count(*) as raw_rows,
           count(distinct id) as distinct_ids,
           max(loaded_at) as latest_loaded_at,
           count(distinct source_file) as files_loaded
    from {TABLE}
"""))
