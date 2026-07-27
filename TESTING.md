# Testing & Data Quality

How data quality is enforced in this project: the kinds of checks, the
severity convention, where each kind lives, and the full rule inventory.

> Scope note: this documents the **dbt** test layer. It is the source of
> truth for DQ — if you add or change a check, update the relevant table here.

---

## 1. The five mechanisms

| Mechanism | Where | Runs on | Gates the build? | Purpose |
|---|---|---|---|---|
| **Generic (YAML) tests** | `_*__models.yml`, `_seeds.yml` | `dbt test` / `dbt build` | Yes (unless `warn`) | Column contracts: PK, not-null, accepted values, relationships |
| **Singular tests** | `tests/*.sql` | `dbt test` / `dbt build` | Yes (unless `warn`) | Bespoke row-level assertions that don't fit a generic test |
| **Source freshness** | `_*__sources.yml` | `dbt source freshness` | Separate command | Detect stale ingestion (watermark too old) |
| **DQ models** | `models/dq/*.sql` | `dbt build` | No (they build, they don't fail) | Durable, queryable tables of bad/interesting rows for triage |
| **Profiling analyses** | `analyses/*.sql` | Manual (`dbt compile` → run by hand) | No | One-off exploration; never part of the gate |

Global config (`dbt_project.yml`):

- `tests: +store_failures: true` — **every failing test writes its offending
  rows** to the `test_failures` schema (`<test_name>` tables). So a red test is
  debuggable: query the stored failures instead of re-deriving them.
- `models/dq` → materialized as **view**, schema `ust_dq`, tag `dq`.

---

## 2. Severity: `error` vs `warn`

Every generic/singular test has a severity. Default is **error**.

- **error** — a failure makes `dbt build`/`dbt test` exit non-zero → **blocks
  the pipeline / CI**. Use for invariants that must hold.
- **warn** — a failure logs a warning but the run stays green. Use for checks
  that are *expected to fail sometimes* or are pending an upstream fix.

In YAML:

```yaml
# error (default)
tests: [unique, not_null]

# warn
- unique:
    config: {severity: warn}
```

### Where `warn` is used here, and why

| Area | Check | Why warn (not error) |
|---|---|---|
| **jdawms staging** | all `unique` / `unique_combination` / `relationships` | The WMS replica is **append-ingested** and can hold >1 `loaddate` version per natural key. Duplicates are expected until the int layer dedupes latest-per-key. `not_null` on the same keys stays **error** (a missing key is always wrong). |
| `int_events_decoded.description_code` | `relationships` → `seed_event_codes` | Real apps emit codes not yet in the dictionary; these are captured in `dq_unmapped_event_codes`, not blocked. |
| `seed_category_name_aliases.category_id` | `relationships` → `source(mysql, category)` | ~144 brand ids are missing from the Databricks replica (holds only a subset of `ust_category`). Flip to `error` once replication is fixed. |

---

## 3. Singular test vs DQ model — when to use which

They overlap (both can persist rows, thanks to `store_failures`), but the
**intent and DAG role differ**:

- **Singular test** (`tests/`) — a *test node*. Its job is to **alarm**: return
  rows → the build fails/warns. It is not part of the model DAG and nothing
  refs it. Reach for it when a single SQL predicate expresses the rule and you
  want it to gate (or warn on) every build.

- **DQ model** (`models/dq/`) — a first-class *model*. Its job is to
  **collect**: it builds a queryable, documented table of the bad/interesting
  rows and does **not** fail the build. Reach for it when you want ongoing,
  inspectable drift monitoring (most-frequent-first, with triage columns) or a
  quarantine that downstream models deliberately exclude.

**Decision rule**

- Must block or warn the pipeline on violation → **YAML test** or **singular test**.
- Ongoing drift/quarantine to inspect and triage → **DQ model** in `models/dq/`.
- One-off investigation of a new export → **`analyses/`**.

---

## 4. Rule inventory

Severity is **error** unless marked `(warn)`.

### 4.1 Singular tests (`tests/`)

- **assert_sales_agents_have_sales_code** *(warn)* — sales-app events
  (`PDA-A`, `CatalogFS-I`, `CatalogFS-A`) must carry a non-null/non-empty
  `sales_code`.

### 4.2 DQ models (`models/dq/`)

Monitoring tables (each also tests `unique`+`not_null` on its key):

- **dq_quarantine_invalid_source** — system_event_log rows whose `source` is not
  a known app code (scanner/bot/injection payloads). Excluded from
  `int_events_decoded`. Key: `entity_id`.
- **dq_unmapped_event_codes** — `description_code`s seen in data but missing from
  `seed_event_codes`; `is_well_formed_code` separates real dictionary gaps from
  junk. Key: `description_code`.
- **dq_unmatched_demand_skus** — well-formed demand SKUs matching no WMS item
  (`int_jdawms_items`). Keeps the ~11% payload loss visible. Key: `sku`.

### 4.3 Source freshness

| Source table | Warn after | Error after | Watermark |
|---|---|---|---|
| `mysql.system_event_log` | 24h | **72h** | `created_at` |
| `jdawms.dlytrn`, `inv_snap`, `shipment`, `shipment_line` | 48h | — | `loaddate` |
| all other `jdawms.*` (invdtl, invlod, invsub, invsum, locmst, pckwrk_dtl, pckwrk_hdr, prtdsc, prtftp, prtftp_dtl, prtmst, rplcfg) | 168h | — | `loaddate` |

`mysql.admin_users` and `mysql.category` have no freshness (no reliable watermark).

### 4.4 Staging tests

**MySQL**

| Model | Rules |
|---|---|
| stg_mysql__system_event_log | `entity_id` unique+not_null; `source` not_null; `description_code` not_null |
| stg_mysql__admin_users | `user_id` unique+not_null |
| stg_mysql__category | `entity_id` unique+not_null |

**jdawms** — all uniqueness at **warn** (see §2); `not_null` at error.

| Model | Rules |
|---|---|
| dlytrn | `dlytrn_id` not_null + unique(warn) |
| inv_snap | `inv_snap_id` not_null + unique(warn) |
| invdtl | `dtlnum` not_null + unique(warn); `subnum`→invsub rel(warn) |
| invlod | `lodnum` not_null + unique(warn) |
| invsub | `subnum` not_null + unique(warn); `lodnum`→invlod rel(warn) |
| invsum | combo [wh_id, stoloc, prtnum, prt_client_id, invsts](warn); `stoloc`, `prtnum` not_null |
| locmst | combo [wh_id, stoloc](warn); `stoloc` not_null |
| pckwrk_dtl | `wrkref_dtl` not_null + unique(warn); `wrkref`→pckwrk_hdr rel(warn) |
| pckwrk_hdr | `wrkref` not_null + unique(warn) |
| prtdsc | combo [colnam, colval, locale_id](warn) |
| prtftp | combo [prtnum, ftpcod, prt_client_id, wh_id](warn) |
| prtftp_dtl | combo [prtnum, ftpcod, prt_client_id, wh_id, uomcod, uomlvl](warn) |
| prtmst | combo [prtnum, prt_client_id, wh_id_tmpl](warn) |
| rplcfg | PK not_null + unique(warn) |
| shipment | `ship_id` not_null + unique(warn) |
| shipment_line | `ship_line_id` not_null + unique(warn); `ship_id`→shipment rel(warn) |

### 4.5 Intermediate tests

- **int_events_decoded** — `entity_id` not_null+unique; `source_code` not_null +
  accepted_values (11 app codes); `description_code` not_null +
  relationships→`seed_event_codes` *(warn)*; `actor_type` [sales, customer]
- **int_events_enriched** — `entity_id` not_null+unique; `outcome` [success, fail];
  `feature_name` [search, filter, icon_click, catalog_view, item_detail,
  image_enlarge, oos_check]; `page_context` [promo, backorder, history, suggest]
- **int_item_demand_daily** — combo [sku, activity_date, source_system];
  `activity_date`, `sku` not_null
- **int_jdawms_inventory_daily** — combo [prtnum, prt_client_id, wh_id,
  snapshot_date]; `prtnum`, `snapshot_date` not_null
- **int_jdawms_items** — combo [prtnum, prt_client_id]; `prtnum` not_null

### 4.6 Mart tests

- **fct_orders** — `increment_id` unique+not_null; `submitted_at` not_null
- **fct_events** — `entity_id` unique+not_null
- **fct_order_cycles** — `cycle_id` unique+not_null; `customer_key` not_null;
  `cycle_status` [submitted, abandoned, open]; `segment_name` [churner,
  quick_reorder, browser, mixed]
- **mart_rep_weekly** — `sales_code`, `week_start` not_null
- **mart_customer_weekly** — `customer_key`, `week_start` not_null;
  `service_mode` [self_service, sales_assisted, mixed]
- **mart_feature_pairing** — `week_start`, `feature_a`, `feature_b` not_null
- **mart_item_demand_supply** — combo [prtnum, week_start]; `prtnum` not_null +
  relationships→`int_jdawms_items`; `week_start` not_null; `signal`
  [missed_opportunity, restock_risk, promote_candidate, healthy]

### 4.7 Seed tests

Tests only run for **enabled** seeds. These are enabled:

- **seed_event_codes** — `description_code` unique+not_null; `function_name`
  not_null; `payload_format` accepted_values (9)
- **seed_app_sources** — `source_code` unique+not_null; `user_type` [Sales,
  Customer]; `platform` [iOS, Android, Web]
- **seed_categories** — `category_id` unique+not_null; `category_name` not_null
- **seed_app_category_codes** — `app_category_code` unique+not_null; `code_type`
  [real_category, virtual_slot]; `category_name` not_null
- **seed_category_name_aliases** — `raw_name` unique+not_null;
  `category_id`→source(mysql, category) *(warn)*; `alias_type` not_null +
  accepted_values (6)
- **seed_layout_codes** — `layout_code` unique+not_null; `layout_name` not_null
- **seed_warn_event_codes** — `description_code` unique+not_null; `log_level` not_null
- **seed_jdawms_code_descriptions** — combo [code_domain, code_value];
  `code_domain`, `code_value`, `long_description` not_null

**Disabled seeds** (`+enabled: false` — CSVs kept as reference, tests do NOT run):
`seed_tracking_event_types`, `seed_tracking_methods`, `seed_tracking_sources`,
`seed_tracking_icons`, `seed_activity_types`, `seed_activity_methods` (legacy
tracking/activity streams, superseded by the system_event_log spine);
`seed_jdawms_data_dictionary`, `seed_jdawms_comtyp` (read directly from CSV by
the glossary/mock scripts, never `ref()`d).

---

## 5. Running the checks

```bash
dbt build                       # run models + tests together (the pipeline gate)
dbt test                        # tests only
dbt test --select stg_jdawms__inv_snap     # tests for one model
dbt test --select source:mysql             # tests on a source
dbt build --select +mart_item_demand_supply   # a model and everything it needs

dbt source freshness            # freshness only (separate from dbt test)
dbt build --select dq           # build the DQ monitoring tables (tag: dq)
```

Failing test rows are stored in the **`test_failures`** schema — query them to
debug a red test.

---

## 6. Known gaps

- **jdawms coded columns are unvalidated.** No `accepted_values` /
  relationship-to-seed checks on `invsts`, `pcksts`, `locsts`, `actcod`,
  `rcvsts`, etc., even though `seed_jdawms_code_descriptions` exists.
- **No `_rescued_data is null` check.** `dlytrn`, `inv_snap`, `shipment` carry a
  `_rescued_data` column; a non-null value signals ingestion schema drift and
  currently goes unnoticed.
- **`loaddate` is untested.** It is the freshness watermark on every jdawms
  table but has no `not_null` check.
