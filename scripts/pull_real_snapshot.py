"""Copy real Databricks source tables into data/real/ for local testing (READ-ONLY).

Local dev normally runs on data/mock, which is synthetic for NAV and WMS — so a
promo item can never join to the item master there, and a matcher tested on it
proves nothing. This pulls the RAW source tables, unchanged, into data/real/
with the same folder layout as data/mock, so the existing dbt staging models
run over real rows:

    python scripts/pull_real_snapshot.py                  # the promo pipeline's sources
    python scripts/pull_real_snapshot.py --tables navrep.item
    dbt build --select +tag:promo --vars '{local_data_root: data/real}'

Only SELECTs are issued; nothing is written to Databricks. Uses the everyday
DATABRICKS_TOKEN PAT (SQL-scoped) through the SQL warehouse in profiles.yml.
data/ is git-ignored, so none of this is ever committed.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd() / "scripts"))
try:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
except NameError:
    pass

from promo_common import DATABRICKS_HOST, CATALOG, local_data_root  # noqa: E402

HTTP_PATH = os.environ.get("DATABRICKS_HTTP_PATH", "/sql/1.0/warehouses/e165fed86011619a")

# <uc schema>.<table>  ->  <folder under data/real>/<file>.parquet
# The folder names are the ones the dbt sources read (see their external_location).
DEFAULT_TABLES = {
    "social.mentions": "mentionlytics/mentions_databricks.parquet",
    "navrep.item": "navrep/item.parquet",
    "jdawmsrep.prtmst": "jdawmsrep/prtmst.parquet",
    "jdawmsrep.prtdsc": "jdawmsrep/prtdsc.parquet",
}


def pull(tables: dict, out_root: Path) -> None:
    from databricks import sql
    import pyarrow.parquet as pq

    token = os.environ.get("DATABRICKS_TOKEN")
    if not token:
        raise SystemExit("DATABRICKS_TOKEN is not set (the SQL-scoped PAT is enough).")
    with sql.connect(server_hostname=DATABRICKS_HOST, http_path=HTTP_PATH, access_token=token) as conn:
        with conn.cursor() as cur:
            for uc_name, rel_path in tables.items():
                cur.execute(f"select * from {CATALOG}.{uc_name}")
                arrow = cur.fetchall_arrow()
                out = out_root / rel_path
                out.parent.mkdir(parents=True, exist_ok=True)
                pq.write_table(arrow, out)
                print(f"  {uc_name:22s} {arrow.num_rows:>9,} rows -> {out}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tables", nargs="*", help="uc schema.table names (default: the promo pipeline's sources)")
    ap.add_argument("--out-root", default="data/real")
    args = ap.parse_args(argv)
    tables = DEFAULT_TABLES
    if args.tables:
        unknown = [t for t in args.tables if t not in DEFAULT_TABLES]
        if unknown:
            raise SystemExit(f"no local layout known for {unknown}; add them to DEFAULT_TABLES")
        tables = {t: DEFAULT_TABLES[t] for t in args.tables}
    print(f"pulling {len(tables)} table(s) from {CATALOG} (read-only)")
    pull(tables, local_data_root(args.out_root))


if __name__ == "__main__":
    main()
