#!/usr/bin/env python3
"""
Empty dev fixtures for the mentionlytics sources, so the social chain BUILDS.

    python scripts/generate_social_mock.py          # fill in what is missing
    python scripts/generate_social_mock.py --force  # rewrite every fixture

WHY THIS EXISTS. data/ is gitignored, so none of the mentionlytics parquet
travels with a clone. Two of the five source tables -- concept_canon and
product_profile -- had no fixture at all, and without them 44 downstream nodes
could not be built in dev: stg_mentionlytics__concept_canon failed on
"No files found that match the pattern", int_social_trend_board never got built,
and mart_social_trending_items then failed on a table that did not exist.

The practical cost of that was not a red build. It was that a change to any
social model could not be exercised locally AT ALL, so the only way to ship one
was to reason about it and hope -- which is exactly how a change gets merged
that compiles and is wrong. Running this takes the local suite from 386 to 490.

ZERO ROWS, DELIBERATELY. These are SCHEMA fixtures, nothing more. They let dbt
compile and execute every model and prove the SQL is structurally sound against
its real inputs; they do not exercise behaviour, and a build that passes on them
says nothing about whether a number is right. concept_resolution.parquet, which
predates this script, is also 0 rows -- this follows that convention rather than
inventing a second one.

Generating plausible social rows would be worse than useless. The chain runs
through LLM enrichment, canonicalisation and a fade-weighted ranking whose
inputs are real post counts; invented rows would produce a board that looks
right and means nothing, and the navrep mock has already taught us what happens
when a fixture's shape quietly disagrees with production -- tests pass on data
that cannot occur.

COLUMNS COME FROM THE SOURCE YML, so a fixture can never drift from what is
declared. It CAN still drift from what a model actually reads: product_profile
declared 3 columns while its staging model selected 6, and the fixture built
from the yml failed on the missing three. The yml is now correct; if a model
grows a column the source does not declare, this script will reproduce that gap
rather than hide it, and the build will say so.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

import pandas as pd
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "models" / "staging" / "mentionlytics" / "_mentionlytics__sources.yml"
OUT = ROOT / "data" / "mock" / "mentionlytics"

# a glob means the fixture is a captured batch, not a single file -- those are
# real data drops and are never written by this script
GLOB = "*"


def fixtures() -> list[tuple[str, pathlib.Path, list[str]]]:
    """(table, destination, columns) for every single-file mentionlytics source."""
    doc = yaml.safe_load(SOURCES.read_text(encoding="utf-8"))
    src = next(s for s in doc["sources"] if s["name"] == "mentionlytics")

    out = []
    for t in src["tables"]:
        loc = (t.get("config") or {}).get("external_location", "")
        # The location is Jinja with NESTED single quotes --
        #   read_parquet('{{ var('local_data_root', 'data/mock') }}/mentionlytics/x.parquet')
        # so a naive r"'([^']+)'" stops inside the var() call and yields "{{ var(".
        # It did, and wrote a file by that name. Match the FILENAME instead; it is
        # the only part that is ever a literal.
        m = re.search(r"/mentionlytics/([^'\"/]+\.parquet)", loc)
        if not m:
            continue
        name = m.group(1)
        if GLOB in name:
            continue                      # a captured weekly drop; leave it alone
        cols = [c["name"] for c in t.get("columns", [])]
        if not cols:
            print(f"  {t['name']}: no columns declared in the yml, skipped")
            continue
        out.append((t["name"], OUT / name, cols))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true",
                    help="rewrite fixtures that already exist")
    args = ap.parse_args()

    OUT.mkdir(parents=True, exist_ok=True)
    wrote = kept = 0
    for table, dest, cols in fixtures():
        if dest.exists() and not args.force:
            print(f"  {table:22} kept     {dest.relative_to(ROOT)} (exists)")
            kept += 1
            continue
        pd.DataFrame({c: pd.Series(dtype="object") for c in cols}).to_parquet(
            dest, index=False)
        print(f"  {table:22} written  {dest.relative_to(ROOT)}  "
              f"({len(cols)} cols, 0 rows)")
        wrote += 1

    print(f"\n  {wrote} written, {kept} already present")
    if wrote:
        print("  the social chain should now build: "
              "dbt build --exclude tag:promo")
    return 0


if __name__ == "__main__":
    sys.exit(main())
