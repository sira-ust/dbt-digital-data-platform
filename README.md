# ustrading System Event Log — dbt project

Models the **System Event Log**: a MySQL table of system/event logs written by
all company apps (PDA, CatalogFS, CatalogFC, Vegas, CatalogSE, Web) via a
unified API. ~600k events/month. **MySQL is read-only for dbt** — nothing
here ever writes back to the source.

Local development runs entirely on **DuckDB** against a sample export — no
live MySQL connection, zero cloud cost. The production engine (Databricks or
Fabric) is TBD, so model SQL stays portable/ANSI-friendly with
engine-specific logic isolated in dispatched macros.

## Local DuckDB workflow

```powershell
# 1. Setup
python -m venv .venv
.\.venv\Scripts\activate
pip install -r requirements.txt
copy profiles.example.yml profiles.yml      # git-ignored; no credentials
$env:DBT_PROFILES_DIR = "."
dbt deps

# 2. Drop raw API JSON pages into data/raw_api/   (see data/README.md)

# 3. Flatten the API pagination envelope -> Parquet (idempotent)
duckdb -c ".read scripts/flatten_api_json.sql"

# 4. Build + test everything
dbt build

# Useful along the way
dbt parse        # compile check, no data needed
dbt compile      # render SQL to target/compiled/
dbt run          # models only
dbt test         # tests only
```

The sample data is the **raw API response JSON** (Laravel-style envelope:
`{code, msg, data: {current_page, data: [events], per_page, total}}`) — the
flatten script unnests `data.data[]`, dedupes pages on `entity_id`, and
writes `data/system_events.parquet`, which the dbt source reads.
`response` payload strings must survive export intact (they are NOT JSON).

## Event code structure

`description_code` is an 8-digit hierarchical string (**keep as string —
leading zeros matter**):

| Digits | Level | Meaning |
|--------|-------|---------|
| 1–2 | L1 | Category (01–19, e.g. 03 Download, 04 Order, 19 Catalog) |
| 3–4 | L2 | Sub-category |
| 5–6 | L3 | Action |
| 7–8 | L4 | Result: `01` Success, `02` Fail, `00` N/A |

The full dictionary lives in `seeds/seed_event_codes.csv` (scaffold — paste
in the complete Section-5 list). Staging derives `l1_code`…`l4_code`,
`is_success`, `is_failure`.

## `response` payload formats (NOT JSON — string parsing)

| Format | Example | Events | Parser macro |
|--------|---------|--------|--------------|
| key:value CSV | `category:8888,visits_num:2,time:15` | Catalog View 19010000, barcode 18010000 | `parse_kv_response()` |
| Positional CSV | `M000072209,CAT,1250.00,45,1100.00,8,ASI325` = increment_id, order_source, grand_total, duration, subtotal, total_item_count, ust_customer_no | Send Order 04xx, Review 05xx/06xx | `response_part()` |
| Duration | `Time:42` | Download successes 03xx01xx | `parse_duration_seconds()` |
| Bare value | a SKU (14xx/15xx), a title (18xx clicks), `Fail`, or empty | various | `nullif(trim(...))` |

Known doc-vs-reality drift exists (e.g. 01020200 carries `response: "1"`
despite the doc saying no payload) — `analyses/profile_mysql_logs.sql` §3
flags such mismatches against the seed instead of failing.

## Two-timezone handling

| Column | Clock | Conversion |
|--------|-------|------------|
| `event_time` | Device **local** time | Subtract the per-row `timezone` offset (`GMT+8` → −8h) → `event_at_utc` |
| `created_at` / `updated_at` | Server, **fixed PST (UTC-8) year-round, no DST** | Constant **+8h** (never tz-rules) → `created_at_utc` / `updated_at_utc` |
| `event_id` | Device epoch milliseconds | Parsed to nullable `event_id_at_utc` (advisory) |

**Never test `event_time <= created_at`** — device clock drift and offline
queueing make cross-clock ordering unreliable. `entity_id` (auto-increment
PK) is the only ordering/dedup/incremental key.

## Layers

```
data/raw_api/*.json  →  scripts/flatten_api_json.sql  →  data/system_events.parquet
                                                              │
staging/   (view)        stg_mysql__system_events — dedup on entity_id, code
                         split, UTC conversion, geo/actor/version derivation
                              │
intermediate/ (view)     int_events_enriched (+ event dictionary & app registry)
                         int_orders_submitted · int_logins · int_downloads
                         int_catalog_views · int_item_interactions
                              │
marts/  (incremental     mart_order_submission_health · mart_download_reliability
        on entity_id)    mart_catalog_engagement · mart_login_activity*
                         mart_product_interactions*          (* = placeholder)
                         mart_sales_agent_performance (daily agent scorecard)
                              │
marts/audit/             mart_event_record_errors (row-level violations)
                         mart_error_summary (triage rollup view)
```

Marts are event-grain and incremental keyed on `entity_id` (new rows always
have higher ids), sized for the ~600k/month volume.

## Seeds (reference data from the API doc)

| Seed | Contents |
|------|----------|
| `seed_event_codes` | Complete Section-5 event dictionary — ~190 codes across L1 01–19 with payload format, geo flag, log level, platforms |
| `seed_app_sources` | All 9 source codes → app, Sales/Customer, iOS/Android/Web (doc §2.3) |
| `seed_categories` | Complete category id → name map — 18 categories incl. virtual sections (1111 New, 7777 HOT, 8888 Promo, 9999 Recommend, 4444 Back Order, 5555 Purchase History) (doc §8.4) |

## Data quality

Three layers — each serves a different audience:

| Layer | Location | Runs | Purpose |
|---|---|---|---|
| **YAML + singular tests** | `_models.yml` files + `tests/` | Every `dbt build` | Pipeline gate — blocks or warns when structural rules break (PK uniqueness, not-null, accepted values, business rules) |
| **Error mart** | `marts/audit/mart_event_record_errors` | Every `dbt build` | Ongoing source monitoring — row-level violations from reference data mismatches (unknown codes, payload drift). Feeds BI/dashboards via `mart_error_summary` |
| **Profiling analysis** | `analyses/profile_mysql_logs.sql` | Manual only | One-off exploration — run against DuckDB after receiving a new data export to understand the data before trusting it |

**Decision rule — where to put a new check:**

- Blocks the pipeline if violated → YAML test or `tests/` singular test
- Ongoing source drift to monitor → `mart_event_record_errors` (add a CTE)
- One-off investigation of a data dump → `analyses/`

**Never build BI on `test_failures` schema** — dbt's internal scratch space; table names are hashed, wiped on every run, not documented.

## Repo structure

```
├── dbt_project.yml              # materialization defaults + seed column types
├── profiles.example.yml         # DuckDB dev target (copy to profiles.yml)
├── dbt-env.ps1                  # load venv into PowerShell session (. .\dbt-env.ps1)
├── data/                        # raw_api/*.json + flattened parquet (git-ignored)
├── scripts/
│   ├── flatten_api_json.sql     # API envelope -> parquet (run before dbt build)
│   └── generate_event_glossary.py  # regenerate seed docs blocks from CSVs
├── analyses/profile_mysql_logs.sql  # manual one-off profiling queries
├── seeds/                       # event codes, app sources, categories
├── macros/                      # parse_response (kv/positional/duration),
│                                # time_convert (fixed-PST + device offsets)
├── tests/                       # singular tests (pipeline integrity checks)
└── models/
    ├── exposures.yml            # downstream BI dashboard definitions
    ├── docs/                    # {% docs %} blocks (auto-generated — do not edit)
    ├── staging/mysql/           # source + stg_mysql__system_events
    ├── intermediate/            # enrichment + per-event-family parsing
    └── marts/
        ├── audit/               # mart_event_record_errors, mart_error_summary
        └── *.sql                # incremental event-grain marts + agent scorecard
```

## Production engine — TBD

DuckDB now; Databricks or Fabric later (followup.md). Rules until decided:

- Portable ANSI SQL in models; `regexp_extract`/`split_part` are the agreed
  baseline (DuckDB + Databricks share signatures; Fabric would need macro
  overrides)
- Engine-specific syntax only in dispatched macros (`macros/`)
- The dbt-duckdb `external_location` on the source is the one deliberate
  local-dev-specific piece — production swaps the source definition only

## Roadmap

| Phase | Scope |
|-------|-------|
| **Phase 1 (now)** | System Event Log → dbt models → Power BI; local DuckDB dev |
| **Phase 2 (future)** | Migrate the Replication table feed (UST-DWH-PROD-IR) from the existing Azure data pipeline into dbt (SQL Server: BC14 ERP, NAV 09, WMS) |

Details: [followup.md](followup.md).
