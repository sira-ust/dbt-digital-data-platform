"""ONE-TIME: upload AI results produced locally into the Databricks social tables.

The staying-power work (2026-10) produced its LLM outputs locally, against a read-only
copy of the real Databricks tables (scripts/pull_real_snapshot.py), so Databricks never
has to pay for them again:

    concept_canon.parquet         every name -> canonical product (+ the consolidation
                                  merges and checkpoint)     -> ust_databricks.social.concept_canon
    product_profile.parquet       branded / shelf / generic + brand per product
                                                             -> ust_databricks.social.product_profile
    mention_enrichment_relabel.parquet
                                  the ~2,040 posts re-labelled from enrichment v1/v2
                                                             -> ust_databricks.social.mention_enrichment

After this, the weekly social job's AI steps find that work DONE and only handle names,
products and posts that are new — see scripts/databricks/social_weekly_job.yml.

SKU matches are deliberately NOT uploaded: the resolver needs the real WMS item and
stock tables, which the local copy only mocks, so it runs on Databricks (and resolves
only the board products it has not resolved yet).

SAFE TO RE-RUN. Each table gets only the rows it does not already hold (an anti-join on
the row's identity), so a second run inserts nothing. Without --confirm it only reports
what it would insert.

    python scripts/bootstrap_social_ai_results.py --from data/social_bootstrap            # preview
    python scripts/bootstrap_social_ai_results.py --from data/social_bootstrap --confirm  # write

Auth: a browser sign-in (your own permissions). The everyday DATABRICKS_TOKEN PAT is
SQL-only and cannot upload files. The parquet files go to
/Volumes/ust_databricks/social/landing/_bootstrap/ — a subfolder, which parse_mentions.py
(it reads landing/*.xlsx only) never touches.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

HOST = os.environ.get("DATABRICKS_HOST", "adb-7405618436278207.7.azuredatabricks.net").replace("https://", "")
HTTP_PATH = os.environ.get("DATABRICKS_HTTP_PATH", "/sql/1.0/warehouses/e165fed86011619a")
VOLUME_DIR = "/Volumes/ust_databricks/social/landing/_bootstrap"

# file -> (target table, identity columns, all-string table created if missing?)
TABLES = {
    "concept_canon.parquet": (
        "ust_databricks.social.concept_canon",
        ["concept_class", "concept_norm", "canonical_name", "canonicalized_at"], True),
    "product_profile.parquet": (
        "ust_databricks.social.product_profile",
        ["product_key", "model_version", "profiled_at"], True),
    "mention_enrichment_relabel.parquet": (
        "ust_databricks.social.mention_enrichment",
        ["mention_id", "model_version", "enriched_at"], False),
}


def _token() -> str:
    os.environ.pop("DATABRICKS_TOKEN", None)
    from databricks.sdk.core import Config
    return Config(host=f"https://{HOST}", auth_type="external-browser").authenticate()["Authorization"].split(" ", 1)[1]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--from", dest="src", default="data/social_bootstrap")
    ap.add_argument("--confirm", action="store_true", help="actually write (default: preview only)")
    args = ap.parse_args(argv)

    src = Path(args.src)
    files = [f for f in TABLES if (src / f).exists()]
    if not files:
        raise SystemExit(f"no bootstrap files in {src}")

    import pyarrow.parquet as pq
    from databricks import sql
    from databricks.sdk import WorkspaceClient

    token = _token()
    w = WorkspaceClient(host=f"https://{HOST}", token=token)
    with sql.connect(server_hostname=HOST, http_path=HTTP_PATH, access_token=token) as conn, conn.cursor() as cur:
        for f in files:
            table, keys, create = TABLES[f]
            schema = pq.read_schema(src / f)
            cols = [c for c in schema.names]
            print(f"\n{f}: {pq.read_metadata(src / f).num_rows:,} rows -> {table}")
            remote = f"{VOLUME_DIR}/{f}"
            if args.confirm:
                with open(src / f, "rb") as fh:
                    w.files.upload(remote, fh, overwrite=True)
                if create:
                    ddl = ", ".join(f"`{c}` string" for c in cols)
                    cur.execute(f"create table if not exists {table} ({ddl}) using delta")
            # target columns and types, to cast the file's columns to them
            try:
                cur.execute(f"describe table {table}")
                target = {r[0]: r[1] for r in cur.fetchall() if r[0] and not r[0].startswith("#")}
            except Exception:
                target = {c: "string" for c in cols}          # preview before the table exists
            shared = [c for c in cols if c in target]
            missing = [c for c in cols if c not in target]
            if missing:
                print(f"  note: {missing} not in {table} — "
                      + ("added" if args.confirm else "would be added") + " as string columns")
                if args.confirm:
                    cur.execute(f"alter table {table} add columns ("
                                + ", ".join(f"`{c}` string" for c in missing) + ")")
                    shared += missing
                    target.update({c: "string" for c in missing})
            if not args.confirm:
                print(f"  preview only: would insert the rows not already in {table}, keyed on {keys}")
                continue
            select = ", ".join(f"cast(s.`{c}` as {target[c]}) as `{c}`" for c in shared)
            on = " and ".join(f"cast(s.`{k}` as string) <=> cast(t.`{k}` as string)" for k in keys)
            cur.execute(f"select count(*) from {table}")
            before = cur.fetchone()[0]
            cur.execute(f"""
                insert into {table} ({', '.join(f'`{c}`' for c in shared)})
                select {select}
                from read_files('{remote}', format => 'parquet') as s
                where not exists (select 1 from {table} as t where {on})
            """)
            cur.execute(f"select count(*) from {table}")
            print(f"  inserted {cur.fetchone()[0] - before:,} new rows ({before:,} were already there)")
    print("\ndone" if args.confirm else "\npreview done — re-run with --confirm to write")


if __name__ == "__main__":
    main()
