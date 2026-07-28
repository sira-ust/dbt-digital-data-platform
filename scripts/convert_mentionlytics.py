"""Convert a weekly Mentionlytics xlsx export into parquet for dbt staging.

Pre-dbt helper (run once per weekly file drop, before `dbt build`), in the same
spirit as scripts/generate_jdawms_mock.py. It does the minimum structural prep so
stg_mentionlytics__mentions can read the data via read_parquet():

  * reads the `mentions` sheet only (the `Notes` sheet is ignored)
  * normalises the 24 raw headers to stable snake_case identifiers
  * adds two lineage columns the rerunnable dedup relies on:
      - loaded_at   : export/ingest time; latest wins when the same mention_id
                      appears in more than one weekly file
      - source_file : which xlsx the row came from
  * writes data/mock/mentionlytics/mentions_YYYYMMDD.parquet

It deliberately does NOT cast, trim, decode, or dedupe — all of that lives in the
staging model so there is a single place transformations happen. Values are
written through as openpyxl/pandas read them.

Usage:
    python scripts/convert_mentionlytics.py <export.xlsx> [--loaded-at 2026-07-24] [--out-dir DIR]

loaded_at is resolved in this order: --loaded-at arg > a YYYYMMDD / YYYY-MM-DD in
the filename > the file's modification time.
"""

from __future__ import annotations

import argparse
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd

SHEET = "mentions"
DEFAULT_OUT_DIR = Path("data/mock/mentionlytics")

# The 24 raw headers, in export order, for a presence check. Unexpected headers
# are still carried through (slugified) so a Mentionlytics tweak doesn't drop data.
EXPECTED_HEADERS = [
    "ID", "Channel", "Category", "Profile", "Profile Visits (Web only)",
    "Profile Users (Web only)", "Language", "Followers/Rank", "Total Engagement",
    "Total Engagement with views", "Likes", "Comments", "Shares", "Views",
    "Impressions", "Date", "Sentiment", "Title", "Content", "Country",
    "Location", "Tracker", "Keyword", "Link",
]


def slugify(header: str) -> str:
    """Lowercase, turn any run of non-alphanumerics into a single underscore.

    'Profile Visits (Web only)' -> 'profile_visits_web_only'
    'Followers/Rank'            -> 'followers_rank'
    """
    slug = re.sub(r"[^0-9a-z]+", "_", str(header).strip().lower())
    return slug.strip("_")


def resolve_loaded_at(path: Path, arg: str | None) -> datetime:
    """Determine the export timestamp: arg > date-in-filename > file mtime."""
    if arg:
        # accept a date (YYYY-MM-DD) or a full ISO datetime
        try:
            return datetime.fromisoformat(arg)
        except ValueError:
            return datetime.strptime(arg, "%Y%m%d")

    m = re.search(r"(20\d{2})[-_]?(\d{2})[-_]?(\d{2})", path.stem)
    if m:
        return datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)))

    return datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc).replace(tzinfo=None)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xlsx", type=Path, help="Path to the Mentionlytics export .xlsx")
    parser.add_argument("--loaded-at", help="Override export date/datetime (else derived)")
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    args = parser.parse_args()

    if not args.xlsx.exists():
        print(f"ERROR: file not found: {args.xlsx}", file=sys.stderr)
        return 1

    loaded_at = resolve_loaded_at(args.xlsx, args.loaded_at)

    df = pd.read_excel(args.xlsx, sheet_name=SHEET)

    missing = [h for h in EXPECTED_HEADERS if h not in df.columns]
    unexpected = [h for h in df.columns if h not in EXPECTED_HEADERS]
    if missing:
        print(f"WARNING: expected headers missing: {missing}", file=sys.stderr)
    if unexpected:
        print(f"WARNING: unexpected headers carried through: {unexpected}", file=sys.stderr)

    df = df.rename(columns={h: slugify(h) for h in df.columns})

    # lineage columns for the rerunnable dedup (latest loaded_at wins)
    df["loaded_at"] = pd.Timestamp(loaded_at)
    df["source_file"] = args.xlsx.name

    args.out_dir.mkdir(parents=True, exist_ok=True)
    out_path = args.out_dir / f"mentions_{loaded_at:%Y%m%d}.parquet"
    df.to_parquet(out_path, index=False)

    print(f"rows written     : {len(df)}")
    print(f"loaded_at        : {loaded_at.isoformat()}")
    print(f"source_file      : {args.xlsx.name}")
    print(f"output           : {out_path}")
    print(f"columns ({len(df.columns)}) : {list(df.columns)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
