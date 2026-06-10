# Follow-up — outstanding decisions

Tracked questions for the dbt MySQL reporting track. Update as decisions are made; link PRs or docs where relevant.

> **Scope decision (2026-06-09):** dbt starts with **MySQL DB only**. The existing Azure data pipeline (SQL Server → Replication table → ADF → load/validate/normalize/lookups/ML → Magento 2) is already running and stays unchanged — dbt does **not** duplicate that work. NAV/WMS/SQL Server sources are out of scope for Phase 1.

## Roadmap

| Phase | Scope | Status |
|-------|-------|--------|
| **Phase 1 (now)** | dbt reads MySQL DB directly → staging → marts → Power BI | Structure draft |
| **Phase 2 (future)** | Migrate the Replication table feed (UST-DWH-PROD-IR) from the existing Azure data pipeline into dbt | Not started — see [Future state](#future-state--replication-table-migration-into-dbt) |

## Decision summary

| # | Topic | Status | Decision |
|---|-------|--------|----------|
| 1 | MySQL connection method (prod) | **TBD** | Local dev: DuckDB over sample Parquet exports (decided). Production: depends on engine choice (Databricks Lakehouse Federation vs Fabric mirroring/ADF) |
| 1b | Production engine | **TBD** | Databricks vs Fabric — deferred; models kept portable (ANSI SQL + dispatched macros) |
| 2 | NAV 09 vs NAV 14 lineage | **Phase 2** | Deferred with the Replication table migration — revisit when SQL Server data enters dbt scope |
| 3 | MySQL table / column inventory | **Resolved** | Full API documentation received — System Event Log schema, event-code dictionary, and payload formats are now modeled in the repo (see README). Remaining: exact MySQL table name; paste full Section-5 dictionary into seed_event_codes |
| 4 | Unity Catalog naming | **TBD** | — |
| 5 | Magento data path | **Out of scope** | Magento flows through BC14 into SQL Server — existing pipeline territory |
| 6 | Deployment & orchestration | **TBD** | — |
| 7 | Calendar (dim_date / MTD) | **TBD** | — |
| 8 | Mart consumers | **Deferred** | Power BI is the target per diagram, but do not design contracts yet |
| 9 | dbt test alerting | **TBD** | Diagram shows Logic App email on test failure — wiring TBD |

---

## 1. MySQL connection method — TBD

The diagram shows dbt reading MySQL **directly** (no ADF landing). On Databricks the standard option is **Lakehouse Federation**: a Unity Catalog `CONNECTION` to MySQL plus a foreign catalog, letting dbt query MySQL tables as `{catalog}.{schema}.{table}`.

**What we need**

- Confirm Lakehouse Federation vs alternatives (JDBC reads in a notebook job, ADF copy to Delta, Azure Database for MySQL replica)
- MySQL host, port, database name; network path from Databricks (VNet peering / private endpoint?)
- Read-only credential and secret scope
- Load on production MySQL — is a read replica needed?

**Repo impact**

- `scripts/bootstrap_mysql_federation.sql` — connection + foreign catalog DDL
- `dbt_project.yml` — `mysql_catalog` / `mysql_schema` vars
- `models/sources/_sources.yml` — source database/schema

**Open questions**

- [ ] Is the MySQL server reachable from the Databricks workspace network?
- [ ] Federation query performance acceptable, or should staging models be materialized as tables (snapshot copies) instead of views?
- [ ] Refresh cadence expectations for Power BI?

---

## 2. NAV 09 vs NAV 14 lineage — Phase 2 (deferred)

Previously decided: both ERPs land in SQL Server 2014 and rows must be distinguishable by origin (NAV 09 via UST-DB1, BC14 via UST-NAV). This data now reaches Azure through the Replication table and the existing pipeline, which dbt does not touch in Phase 1.

**Revisit during the Replication table migration (Phase 2)** — the `erp_version` staging-column pattern from the earlier draft can be restored from git history.

---

## 3. MySQL table / column inventory — TBD (blocking)

**Known risk:** the diagram places `fct_orders`, `dim_customers`, and `dim_products` in the dbt track, but describes MySQL as "website cache + app logs" only. Orders, customers, and products primarily live in Magento/MariaDB and SQL Server — both out of scope for Phase 1. Either MySQL contains more transactional data than the label suggests, or those models wait for Phase 2.

**What we need**

- List of MySQL tables relevant to reporting (current stubs: `app_logs`, `website_cache`)
- Confirm whether orders / customers / products exist in MySQL — decides the feasibility of `fct_orders`, `dim_customers`, `dim_products`, and `mart_sales` in Phase 1
- Column names, types, primary keys, and timestamps for incremental logic
- App log payload structure (JSON?) for sessionization

**Repo impact**

- `models/sources/_sources.yml`
- `models/staging/mysql/`
- All intermediate/fact/dim stubs

**Open questions**

- [ ] Schema export or `SHOW CREATE TABLE` dumps available?
- [ ] Data volumes and retention in MySQL (affects view vs table staging)?
- [ ] If sales data is NOT in MySQL: does `mart_sales` move to Phase 2, leaving Phase 1 focused on `mart_web_activity`?

---

## 4. Unity Catalog naming — TBD

**What we need**

- Catalog names per environment (draft uses `ust_dev`, `ust_prod`)
- Schema layout: `staging`, `intermediate`, `marts`, `seeds`, `snapshots`, `test_failures`
- Name of the federated MySQL catalog (draft: `mysql_federated`)

**Repo impact**

- `profiles.yml.example`, `dbt_project.yml`, `scripts/bootstrap_mysql_federation.sql`

**Open questions**

- [ ] Single workspace with catalog-per-env, or workspace-per-env?
- [ ] Service principal / grants for the dbt runner?

---

## 5. Magento data path — Out of scope

Magento / MariaDB flows through BC14 into SQL Server 2014 and onward through the existing Azure pipeline. Not a dbt source. No repo impact in Phase 1; e-commerce data would arrive in dbt via the Phase 2 Replication table migration.

---

## 6. Deployment & orchestration — TBD

**What we need**

- Where dbt runs: Databricks Job, dbt Cloud, Azure DevOps, GitHub Actions
- Schedule — independent of ADF since dbt reads MySQL directly; what cadence does Power BI need?
- Secrets management (Key Vault, Databricks secret scope)

**Repo impact**

- `.github/workflows/dbt-ci.yml` — currently parse-only
- Future: Databricks job definition

**Open questions**

- [ ] Who owns the production dbt run?
- [ ] Branch strategy: `main` → prod, `develop` → dev?

---

## 7. Calendar (dim_date / MTD) — TBD

**What we need**

- Calendar vs fiscal year (and fiscal start month)
- Holiday calendar; timezone for day boundaries (draft: `Asia/Bangkok`)
- Reporting date range

**Repo impact**

- `seeds/dim_date.csv` (header-only stub), `analyses/generate_dim_date.sql`, `models/marts/core/dimensions/dim_date.sql`

---

## 8. Mart consumers — Deferred

Power BI is the consumer per the diagram (sales & web dashboards), but **do not design mart contracts yet**. `mart_sales` and `mart_web_activity` are structural placeholders. Revisit when dashboard requirements (grain, columns, refresh SLA) are defined.

---

## 9. dbt test alerting — TBD

The diagram routes dbt test failures to **Logic App email** (same alerting pattern as the existing pipeline's validation step, which logs to `USTValidationLog`).

**What we need**

- How test failures trigger the Logic App: orchestrator parses `dbt test` results? Logic App polls `test_failures` schema? Webhook from dbt Cloud?
- Recipient list and severity rules

**Repo impact**

- `tests:` config in `dbt_project.yml` already stores failures to the `test_failures` schema as a hook point
- Orchestration wiring lands with #6

---

## Future state — Replication table migration into dbt

Today, on-prem SQL Servers (UST-NAV / BC14, UST-DB1 / NAV 09, UST-DB9 / WMS) replicate into the **Replication table (UST-DWH-PROD-IR)**, which ADF picks up into the existing Azure data pipeline (load → validate → normalize → lookups → ML → Magento 2). That pipeline is already running, so Phase 1 deliberately avoids duplicating it.

**Target future state:** migrate the Replication table feed into the dbt track so SQL Server data (ERP, WMS, Magento-via-BC14) is modeled alongside MySQL data in dbt.

**What migration would involve**

- New dbt sources over the replicated data (either the ADF Parquet landing in `raw_data/` or a federation/CDC path — TBD)
- Re-implement the pipeline's validate/normalize/lookup logic as dbt staging + intermediate models with dbt tests (replacing `USTValidationParams` / `USTValidationLog` rule logic)
- Restore the `erp_version` lineage pattern for NAV 09 vs BC14 (see #2)
- Extend `fct_orders` / `dim_customers` / `dim_products` / `mart_sales` to full ERP grain
- Decide the fate of the ML recommendation step (stay in the existing pipeline vs orchestrated after dbt)
- Parallel-run and reconciliation strategy before any cutover; Magento 2 consumption must not be disrupted

**Preconditions**

- [ ] Phase 1 (MySQL track) running in production with stable orchestration and alerting
- [ ] Inventory of existing pipeline rules (validation params, normalization, lookup definitions)
- [ ] Stakeholder agreement on cutover and reconciliation approach

---

## Suggested order of resolution

1. **#1 MySQL connection** — unblocks everything; validates the direct-read approach
2. **#3 Table inventory** — decides what facts/dims are actually buildable from MySQL in Phase 1
3. **#4 Unity Catalog** — unblocks first successful `dbt run`
4. **#7 Calendar** — needed before time-based marts
5. **#6 Deployment + #9 Alerting** — before production cutover
6. **#8 Consumers** — after core models are validated
7. **Future state** — Replication table migration planning starts only after Phase 1 is stable

---

## Change log

| Date | Author | Change |
|------|--------|--------|
| 2026-06-09 | — | Initial follow-up from architecture draft |
| 2026-06-09 | — | Redirection: dbt starts with MySQL only; SQL Server/NAV/WMS deferred (existing Azure pipeline unchanged); added #9 test alerting |
| 2026-06-09 | — | Added roadmap (Phase 1 / Phase 2), flagged MySQL data-availability risk in #3, documented future state: Replication table migration into dbt |
| 2026-06-09 | — | Local-dev pivot: dbt-duckdb against sample Parquet exports in data/ (engine decision deferred — Databricks or Fabric later); added profiling script for undocumented log tables; staging redesigned around app-event logs (JSON payload, mixed event types, timestamp normalization, retry dedup); MySQL confirmed read-only for dbt |
| 2026-06-09 | — | API documentation received — §3 RESOLVED. Rebuilt around the documented System Event Log spec: flatten step for raw API JSON (Laravel envelope), seeds for event codes/app sources/categories, staging with 8-digit code split + two-timezone UTC handling (device offset vs fixed PST), per-family payload parsers (kv/positional/duration/bare), event-grain incremental marts on entity_id (~600k events/mo), profiling now validates sample vs seed expectations (flags doc-vs-reality drift like 01020200) |
