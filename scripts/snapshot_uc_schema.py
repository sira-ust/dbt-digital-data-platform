"""One-time snapshot of the Unity Catalog schema for local mock generation.

Queries ust_databricks.information_schema.columns for the jdawmsrep, navrep, and
mysql schemas and writes data/uc_schema_snapshot.csv (git-tracked). This is the
ONLY script that touches Databricks during development — everything downstream
(scripts/generate_jdawms_mock.py, DuckDB dev runs) works from the snapshot.

navrep is the NAV ERP feed. It arrives through the same Azure Blob ingestion as
jdawmsrep but is a separate source system, so it lands in its own UC schema and
is modelled under a separate dbt source (`nav`) — see
models/staging/nav/_nav__sources.yml. The DLT pipeline landed navrep's 15 tables
on 2026-08-11; this snapshot has not been refreshed since, so the committed CSV
still predates them.

Re-run only when the replica schema actually changes (new columns/tables).
Requires DBT_DATABRICKS_TOKEN in the environment; host/http_path mirror
profiles.yml.

Run from the repo root:  python scripts/snapshot_uc_schema.py
"""

import csv
import os
from pathlib import Path

from databricks import sql

HOST = "adb-7405618436278207.7.azuredatabricks.net"
HTTP_PATH = "/sql/1.0/warehouses/e165fed86011619a"
OUT = Path(__file__).resolve().parents[1] / "data" / "uc_schema_snapshot.csv"

QUERY = """
select
    table_schema,
    table_name,
    ordinal_position,
    column_name,
    full_data_type,
    is_nullable
from ust_databricks.information_schema.columns
where table_schema in ('jdawmsrep', 'navrep', 'mysql')
  -- exclude ingestion-pipeline internals (Lakeflow/DLT bookkeeping)
  and table_name not like '\\_\\_materialization%'
  and table_name not like 'event\\_log\\_%'
order by table_schema, table_name, ordinal_position
"""


def main() -> None:
    token = os.environ.get("DBT_DATABRICKS_TOKEN")
    if not token:
        raise SystemExit("DBT_DATABRICKS_TOKEN is not set")

    with sql.connect(server_hostname=HOST, http_path=HTTP_PATH, access_token=token) as conn:
        with conn.cursor() as cur:
            cur.execute(QUERY)
            cols = [d[0] for d in cur.description]
            rows = cur.fetchall()

    with open(OUT, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(cols)
        w.writerows(rows)

    tables = sorted({(r[0], r[1]) for r in rows})
    print(f"{OUT.relative_to(OUT.parents[1])}: {len(rows)} columns across {len(tables)} tables")
    for schema in sorted({s for s, _ in tables}):
        names = [t for s, t in tables if s == schema]
        print(f"  {schema} ({len(names)}): {', '.join(names)}")


if __name__ == "__main__":
    main()
