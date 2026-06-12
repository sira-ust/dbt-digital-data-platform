# ustrading System Event Log — dbt project

Models the **System Event Log**: a MySQL table of system/event logs written by
all company apps (PDA, CatalogFS, CatalogFC, Vegas, CatalogSE, Web) via a
unified API. ~600k events/month. **MySQL is read-only for dbt** — nothing
here ever writes back to the source.

**Phase 1 scope:** source mapping (staging) + parsed intermediate models (event
grain, views) + data quality checks. Aggregated analytics (`fct_*` incremental,
`mart_*` rollups) deferred until BI requirements land.

Local development runs entirely on **DuckDB** against a sample export — no
live MySQL connection, zero cloud cost.

## Local DuckDB workflow

```powershell
python -m venv .venv
. .\dbt-env.ps1
pip install -r requirements.txt
copy profiles.example.yml profiles.yml
dbt deps

# Flatten raw API JSON -> parquet
duckdb -c ".read scripts/flatten_api_json.sql"

dbt build
```

## Layers

```
data/raw_api/*.json  →  scripts/flatten_api_json.sql  →  data/system_events.parquet
                                                              │
staging/mysql/ (view)   stg_mysql__system_events — dedup, types, code split, UTC
seeds/ (CSV)            seed_event_codes · seed_app_sources · seed_categories
                              │
intermediate/ (view)    int_events_enriched (+ dictionary & app registry)
                        int_logins · int_downloads · int_catalog_views
                        int_item_interactions
                              │
marts/core/facts/       fct_orders_submitted (send-order events)
                              │
marts/reporting/        mart_sales_agent_performance (daily rep scorecard)
                              │
dq/                     audit_event_record_errors · audit_error_summary
tests/                  assert_sales_agents_have_sales_code (+ YAML tests)
```

| Layer | Purpose |
|---|---|
| **Source** | `models/staging/mysql/_mysql__sources.yml` — declares `mysql.system_events` |
| **Staging** | `stg_mysql__system_events` — 1:1 source mapping: rename, cast, dedup, timezone, actor rules |
| **Seeds** | Event dictionary + app registry + categories — reference data for DQ rules |
| **Intermediate** | Enrichment + per-family payload parsing at **event grain** — foundation for future `fct_*` / `mart_*` |
| **DQ** | `audit_*` tables — ongoing monitoring of unknown codes, payload drift, etc. |
| **Tests** | YAML generic tests on staging + singular tests in `tests/` |

### Future analytics path (not built yet)

```
int_*  →  fct_*  (thin incremental, same grain)  →  mart_*  (daily × agent, etc.)
```

- **`int_*`** — parsed, enriched, still one row per event. No `GROUP BY`.
- **`fct_*`** — persisted copy of an `int_*` family for BI performance (incremental on `entity_id`).
- **`mart_*`** — aggregated scorecards where grain changes (e.g. daily × agent).

## Data quality

| Layer | Location | Runs | Purpose |
|---|---|---|---|
| **YAML + singular tests** | `_mysql__models.yml` + `tests/` | Every `dbt build` | Pipeline gate — PK, not-null, accepted values |
| **Audit tables** | `models/dq/audit_*` | Every `dbt build` | Ongoing drift monitoring — row-level violations |
| **Profiling analysis** | `analyses/profile_mysql_logs.sql` | Manual | One-off exploration of new exports |

**Decision rule:**

- Blocks/warns the pipeline → YAML test or `tests/` singular test
- Ongoing source drift to monitor → `audit_event_record_errors` (add a CTE)
- One-off investigation → `analyses/`

## Repo structure

```
├── dbt_project.yml
├── profiles.example.yml
├── dbt-env.ps1
├── data/                        # raw_api/*.json + parquet (git-ignored)
├── scripts/
│   ├── flatten_api_json.sql
│   └── generate_event_glossary.py
├── analyses/profile_mysql_logs.sql
├── seeds/
├── macros/
├── tests/
└── models/
    ├── docs/
    ├── staging/mysql/
    ├── intermediate/
    ├── marts/reporting/
    ├── exposures.yml
    └── dq/
```

## Roadmap

| Phase | Scope |
|---|---|
| **Phase 1 (now)** | Source mapping + DQ checks |
| **Phase 2 (future)** | Analytics marts + BI; Replication table / ERP data |

Details: [followup.md](followup.md).
