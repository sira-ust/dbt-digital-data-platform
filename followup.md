# Follow-up — outstanding decisions

> **Scope decision (2026-06-10):** Phase 1 is **source mapping + intermediate
> prep (event-grain views) + DQ**. `fct_orders_submitted`, `mart_sales_agent_performance`,
> and `sales_rep_performance_dashboard` exposure added; other `fct_*` / `dim_*` as needed.

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| **Phase 1 (now)** | Staging → intermediate (parsed, event grain) → DQ | Implemented (DuckDB local dev) |
| **Phase 1b (next)** | `fct_*` + `mart_*` + Power BI when dashboards defined | In progress — orders fact + rep scorecard |
| **Phase 2 (future)** | Replication table / ERP sources | Not started |

## Decision summary

| # | Topic | Status |
|---|---|---|
| 1 | MySQL connection (prod) | TBD — DuckDB local dev decided |
| 1b | Production engine | TBD — Databricks vs Fabric |
| 2 | NAV 09 vs NAV 14 lineage | Phase 2 |
| 3 | MySQL table inventory | Resolved for Phase 1 (`system_events`) |
| 4 | Unity Catalog naming | TBD |
| 5 | Magento data path | Out of scope Phase 1 |
| 6 | Deployment & orchestration | TBD |
| 7 | Analytics marts + BI | Partial — `fct_orders_submitted`, `mart_sales_agent_performance`, exposure; more facts/dims TBD |
| 8 | dbt test alerting | TBD |

## Phase 1 repo (current)

- `models/staging/mysql/` — source declaration + `stg_mysql__system_events`
- `seeds/` — event dictionary, app sources, categories
- `models/intermediate/` — `int_events_enriched` + per-family parsers (event grain)
- `models/dq/` — `audit_event_record_errors`, `audit_error_summary`
- `tests/` — singular DQ tests

## Phase 1b additions (when BI ready)

- `marts/core/facts/` — `fct_*` event-grain facts (e.g. `fct_orders_submitted` from `int_events_enriched`)
- `marts/core/dimensions/` — `dim_*` views over seeds (BI-friendly names)
- `marts/reporting/` — aggregated `mart_*` scorecards
- `models/exposures.yml` — Power BI lineage

## Phase 2 additions

- ERP sources from Replication table migration
