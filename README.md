# ustrading Digital Data Platform — dbt project

Models the **System Event Log** (MySQL — system/event logs written by all
company apps: PDA, CatalogFS, CatalogFC, Vegas, CatalogSE, Web via a unified
API, ~600k events/month) together with the **JDA / Blue Yonder WMS replica**
(`jdawms`, 16 tables), joined for cross-source demand-vs-supply analytics.
**Both sources are read-only for dbt** — nothing here ever writes back.

The pipeline runs staging → intermediate (event / day grain) → facts +
reporting marts, with data-quality tests and DQ monitoring tables throughout
(see [TESTING.md](TESTING.md)).

Local development runs entirely on **DuckDB** against sample/mock data — no
live MySQL or Databricks connection, zero cloud cost.

## Prerequisites

- **Python 3.11+** and **git**
- **No DuckDB install required.** `dbt-duckdb` (in `requirements.txt`) bundles
  the DuckDB engine as a Python package — there is no separate database
  server to install, run, or configure. `dbt build` works right after
  `pip install -r requirements.txt`.
- Windows: PowerShell is the primary shell. If `.venv\Scripts\Activate.ps1` is
  blocked by execution policy on a managed machine, use `dbt-env.ps1` instead
  (below) — it puts the venv on `PATH` and sets `DBT_PROFILES_DIR` without
  needing script execution to be enabled.

## Local DuckDB workflow

```powershell
python -m venv .venv
. .\dbt-env.ps1          # or: .venv\Scripts\Activate.ps1
pip install -r requirements.txt
copy profiles.example.yml profiles.yml
dbt deps

# Generate mock parquet for the jdawms (WMS) source + the two sample-less
# mysql tables (admin_users, category) — schema-exact, from the git-tracked
# UC snapshot; no Databricks/Unity Catalog access or cost (see data/README.md).
python scripts/generate_jdawms_mock.py

dbt build
```

`stg_mysql__system_event_log` reads the real API sample JSON directly (no
flatten step) — the sample must be present under
`data/mock/mysql/raw_api/` (git-ignored; see data/README.md).

## Querying the local database

`dev.duckdb` is a plain file — no server to connect to. A few ways in:

```powershell
# One-off query
python -c "import duckdb; duckdb.connect('dev.duckdb', read_only=True).sql('select * from ust_staging.stg_jdawms__dlytrn limit 10').show()"

# Interactive Python REPL
python
>>> import duckdb
>>> con = duckdb.connect('dev.duckdb', read_only=True)
>>> con.sql("select table_schema, table_name from information_schema.tables order by 1, 2").show()
```

Use `read_only=True` — `dbt build`/`dbt run` hold a lock on the file, and a
read-only connection avoids fighting over it. Tables are schema-prefixed per
`dbt_project.yml` (`ust_staging`, `ust_intermediate`, `ust_dq`,
`ust_reporting`, `ust_seeds`), not bare model names. If `.show()`'s
box-drawing output looks garbled on Windows, set `$env:PYTHONIOENCODING="utf-8"`
first — it's a console codepage issue, not a query problem.

For an interactive SQL shell instead of Python, install the CLI (not in
`requirements.txt` — optional):

```powershell
pip install duckdb-cli
duckdb dev.duckdb
D select * from ust_staging.stg_jdawms__dlytrn limit 10;
```

DBeaver and the VS Code SQLTools/DuckDB extensions can also open `dev.duckdb`
directly if a GUI is preferred.

## Layers

Two source systems flow through staging → intermediate → marts:

```
SOURCES
  mysql               system_event_log · admin_users · category
  jdawms (WMS)        16 replica tables (dlytrn, inv_snap, invdtl, invlod, invsub,
                      invsum, locmst, pckwrk_dtl, pckwrk_hdr, prtdsc, prtftp,
                      prtftp_dtl, prtmst, rplcfg, shipment, shipment_line)
        │
staging/ (view)       stg_mysql__*  (3)  ·  stg_jdawms__*  (16)
                      1:1 lossless: cast, trim, dedup only — no decoding
        │
seeds/ (CSV)          event dictionary · app registry · categories ·
                      jdawms code descriptions  (reference data)
        │
intermediate/ (view)  int_events_decoded         decode 8-digit code, event_time→UTC, location/source parse
                      int_events_enriched        feature / outcome / page_context enrichment
                      int_rep_order_cycle        reconstruct sales-rep order cycles from event bursts
                      int_item_demand_daily      demand per sku × day from view/cart events
                      int_jdawms_items           WMS item master (prtmst + prtdsc names / ABC / velocity)
                      int_jdawms_inventory_daily daily on-hand / shippable per item × warehouse
        │
marts/core/facts/     fct_orders                 one row per submitted order (increment_id)
                      fct_events                 one row per event, decoded + enriched
                      fct_order_cycles           one row per order cycle (rep journey)
        │
marts/reporting/      mart_rep_weekly            weekly sales-rep scorecard
                      mart_customer_weekly       weekly customer activity + churn signal
                      mart_feature_pairing       weekly feature co-occurrence
                      mart_rep_order_journey     rep order-journey detail
                      mart_item_demand_supply    weekly demand × WMS supply per item
        │
dq/                   dq_quarantine_invalid_source · dq_unmapped_event_codes · dq_unmatched_demand_skus
tests/                assert_sales_agents_have_sales_code (+ YAML tests; see TESTING.md)
```

| Layer | Purpose |
|---|---|
| **Source** | `staging/*/_*__sources.yml` — declares the `mysql` and `jdawms` sources (target-dependent: mock on DuckDB, real tables on Databricks) |
| **Staging** | `stg_<source>__*` — 1:1 lossless views: cast, trim, dedup. No decoding or business logic |
| **Seeds** | Event dictionary, app registry, categories, WMS code descriptions — reference data for decoding + DQ |
| **Intermediate** | Decoding, enrichment, and grain shaping (event / day) — the reusable foundation for facts and marts |
| **Facts** | `fct_*` — analytics-ready event / order / cycle grain |
| **Reporting** | `mart_*` — weekly rollups and cross-source (demand × supply) analytics |
| **DQ** | `dq_*` — queryable quarantine / drift-monitoring tables |
| **Tests** | YAML generic tests + singular tests in `tests/` — see [TESTING.md](TESTING.md) |

## Column documentation (glossaries)

Column descriptions live in the source/model YAMLs; text shared by 2+ columns
is deduplicated into `{% docs %}` blocks under `models/docs/` and referenced
via `{{ doc('...') }}` (rule: inline if unique, doc block if shared).

**jdawms is generated, not hand-written.** The SME-verified WMS data dictionary
is the source of truth:

```
seeds/seed_jdawms_data_dictionary.csv       (from wms datadictory_Dbt_2026.xlsx)
        │  scripts/generate_jdawms_glossary.py
        ▼
models/docs/_jdawms_glossary.md             shared {% docs %} blocks
models/staging/jdawms/_jdawms__sources.yml  column descriptions (inline or doc ref)
```

To change a jdawms description: edit the seed CSV → re-run the script →
`dbt parse`. Never hand-edit the generated descriptions. Definitions are
deduplicated by *meaning* — the same column name can legitimately mean
different things per table (e.g. `devcod`), so table-specific variants stay
inline or get a `jdawms__<col>__<table>` block.

**Human-review queue** (the generator prints this on every run):

1. *Variant blocks* — same column, different dictionary text. Confirm each is
   a real semantic difference vs. dictionary phrasing noise.
2. *Empty-comment rows* — dictionary has no `column_comment`; the prior
   AI-inferred text was kept (flagged in the report). Needs SME wording.
3. *Columns not in the dictionary* — `loaddate` / `_rescued_data` are
   pipeline-owned (no SME needed); anything else appearing here means the
   dictionary is out of date.

The mysql glossary (`models/docs/_mysql_glossary.md`) is hand-maintained under
the same inline-vs-shared rule. The event dictionary and seed-value glossaries
are generated by `scripts/generate_event_glossary.py` and
`scripts/generate_seed_value_glossaries.py`.

## Data quality

Full rule inventory, severity convention (`error` vs `warn`), and the
singular-test-vs-DQ-model distinction live in [TESTING.md](TESTING.md).

| Layer | Location | Runs | Purpose |
|---|---|---|---|
| **YAML + singular tests** | `_*__models.yml`, `_seeds.yml`, `tests/` | Every `dbt build` | Pipeline gate — PK, not-null, accepted values, relationships |
| **DQ models** | `models/dq/*` | Every `dbt build` | Ongoing drift monitoring / quarantine — queryable bad-row tables |
| **Profiling analysis** | `analyses/*` | Manual | One-off exploration (demand-vs-supply candidate queries) |

**Decision rule:**

- Blocks/warns the pipeline → YAML test or `tests/` singular test
- Ongoing source drift to monitor / quarantine → a model in `models/dq/`
- One-off investigation → `analyses/`

## Repo structure

```
├── dbt_project.yml
├── profiles.example.yml
├── dbt-env.ps1
├── TESTING.md                          # data-quality rule inventory + conventions
├── data/                               # mock/{jdawmsrep,mysql}/ + UC snapshot (git-ignored, see data/README.md)
├── scripts/
│   ├── generate_event_glossary.py      # event dictionary {% docs %} blocks
│   ├── generate_jdawms_glossary.py     # WMS column glossary (from seed dictionary)
│   ├── generate_seed_value_glossaries.py
│   ├── snapshot_uc_schema.py           # one-time UC schema pull (git-tracked CSV)
│   └── generate_jdawms_mock.py         # mock parquet for local dev (no UC cost)
├── analyses/                           # demand_missed_opportunity · demand_promote_candidates · demand_restock_risk
├── seeds/
├── macros/
├── tests/
└── models/
    ├── docs/
    ├── staging/mysql/
    ├── staging/jdawms/                 # WMS replica staging (databricks: real tables; duckdb: mock parquet)
    ├── intermediate/
    ├── marts/core/facts/
    ├── marts/reporting/
    └── dq/
```

## Roadmap

| Phase | Scope |
|---|---|
| **Phase 1 (done)** | mysql event-log + jdawms WMS staging → intermediate → facts + reporting marts; DQ tests & monitoring; demand-vs-supply analytics |
| **Phase 2 (future)** | Incremental `fct_*` materialization; additional ERP / replication sources; BI layer |
