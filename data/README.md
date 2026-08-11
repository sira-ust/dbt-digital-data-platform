# data/ — local sample of the ustrading System Event Log

Everything here except this README is git-ignored. No sample data is ever
committed.

## Layout

```
data/
  mock/
    mysql/
      raw_api/                <- drop raw API response JSON here (one file per page)
        page_1.json
        page_2.json
        ...
      ust_admin_users.parquet <- generated (no API export exists for these two)
      ust_category.parquet
    jdawmsrep/                <- generated, all 16 tables (no API export exists)
    navrep/                   <- generated, NAV ERP tables (appears once the
                                 navrep schema lands in the UC snapshot)
```

`raw_api/` holds **real** exported API responses — it lives under `mock/`
alongside the generated parquet because, functionally, both serve the same
role in local dev: a stand-in so `dbt build` never has to hit the live
source. See "Mock data" below for the generated (synthetic) side.

## Step 1 — drop the raw API responses

The export is the **raw API response JSON** (Laravel-style pagination
envelope), not a flat table dump:

```json
{ "code": ..., "msg": ..., "data": { "current_page": 1, "data": [ {event}, ... ], "per_page": ..., "total": 611856 } }
```

Event records are at `data.data[]` and match the documented schema
(`entity_id`, `sales_code`, `username`, `ust_customer_no`, `location`,
`timezone`, `event_time`, `source`, `version`, `description_code`,
`response`, `device_name`, `created_at`, `updated_at`, `event_id`).

Multiple page files are fine — `stg_mysql__system_event_log` reads the API
JSON directly from `data/mock/mysql/raw_api/` and unnests the pagination
envelope itself. There is no separate flatten/prep step.

## Important

- **`response` strings must survive export intact.** They are NOT JSON —
  formats vary by event family (`key:value` CSV, positional CSV, `Time:42`,
  bare SKU/title, `Fail`, or empty). No re-encoding, trimming, or flattening.
- The staging model reads the raw API JSON directly (not a parquet). If you
  ever bypass the API and export straight from MySQL, land it with the same
  columns so the source schema still matches.
- This is read-only sample data; dbt never writes back to MySQL.

## Step 2 — build

```bash
dbt build
```

## Mock data for jdawms (WMS) + the two sample-less mysql tables

The jdawmsrep source has no API export at all, and two mysql tables
(`admin_users`, `category`) never had one either. Local DuckDB dev uses
**generated mock parquet** for these — schema-exact to the real Unity Catalog
tables, mirroring the two real schemas under `ust_databricks`:

```
data/
  uc_schema_snapshot.csv          <- git-tracked; landed UC schema (16 jdawmsrep +
                                     7 mysql ust_* tables; navrep once it lands).
                                     Refresh with scripts/snapshot_uc_schema.py
                                     only when the replica schema changes (the
                                     ONLY UC touch).
  mock/
    jdawmsrep/<table>.parquet     <- 16 WMS tables, constraint-aware mock rows
    navrep/<table>.parquet        <- NAV ERP tables. Same Azure Blob ingestion as
                                     jdawmsrep but a separate source system, so a
                                     separate UC schema and a separate dbt source
                                     (`nav`). Mock is type-correct filler only —
                                     no PK/FK awareness until nav staging models
                                     declare tests. Nothing is emitted while
                                     navrep is absent from the snapshot.
    mysql/
      raw_api/                    <- real API export (see Step 1 above);
                                     not generated, kept here as the
                                     mysql-source-system's local stand-in
      ust_admin_users.parquet     <- generated (usernames match the raw_api sample)
      ust_category.parquet        <- generated (ids/names from seed_categories)
```

Of the mysql tables staged in dbt, only `system_event_log` reads the real
`raw_api/` JSON; `admin_users` and `category` are synthetic mock, because
those two never had a real export. (Other mysql tables in the UC snapshot are
not staged in dbt.)

Regenerate any time (deterministic, seeded RNG):

```bash
python scripts/generate_jdawms_mock.py
```

Mock rows satisfy the YAML tests: unique PKs, valid FK chains
(invlod→invsub→invdtl, shipment→shipment_line, pckwrk_hdr→pckwrk_dtl),
unique-combination grains, and fresh `loaddate` values. On the databricks
target the same models read the real replica — `external_location` is ignored
there.
