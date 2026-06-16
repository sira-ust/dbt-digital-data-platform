# Deferred models — backlog

Models the dashboard plan calls for that are **not built yet** because a source
they depend on does not exist today. Per project policy we do not ship stubs,
empty seeds, or placeholder marts — blocked work lives here until its source
lands, then can be built straight from this file.

Spine that already exists and everything below will read from:
`stg_mysql__system_event_log` (lossless) → `int_events_decoded` (decode/parse)
→ `int_events_enriched` (dictionary + app-source joins).

Missing sources referenced below:
- **Order events in the extract** — Group 04 (Send Order) and 09 (Create Order)
  carry `increment_id`; the current API extract contains zero of them.
- **NAV customer master** (`Nav_CustId_CustGroup.xlsx`) — `No_`, Customer
  Posting Group (store type), salesperson assignment, In-Active flag.
- **Address master** (`1.address.csv`) — `No_`, latitude, longitude, address,
  city; for the 100 m geofence.

---

## 1. Order-cycle lineage — BUILT (empty until order events land)

`int_order_cycle` → `fct_order_cycle` → `mart_order_journey` are built and
compile/test green, but return **zero rows** on the current extract because it
contains no Group 04 (submit) or 09 (create) events. They populate
automatically once such events arrive — no further work needed.

- Cycle = open `Create Order (09010000, increment_id)` → close `Group 04 submit
  success`. days_to_close, pending flag, close buckets, pending priority (H/M/L
  by days pending), and behaviour segments (Decisive / Planner / Slow Sender)
  are all **exact** from the order events alone — no add-event linkage.
- **Still deferred on these models** (need per-cycle edit counts, which require
  add↔order linkage that does not exist): the **High Editor** behaviour segment
  and **add-count weighting** of pending priority.

## 2. Page 3 per-cycle metrics (extend cart behaviour)

- **Built now:** `mart_cart_behaviour` at customer grain (add/remove/qty,
  churn ratio, active days).
- **Deferred columns:** churn ratio **per order cycle**, same-day vs multi-day
  cycle timeline. These need add/remove events attributed to a specific
  `increment_id`, which the events do not carry — would require a heuristic
  (attribute edits to the open cycle by customer + time). Not built.
- **Ready when:** the app stamps `increment_id` onto add/remove payloads, or a
  heuristic linkage is explicitly approved.

## 5. `mart_*` store-type segmentation (Pages 1, 2, 3, 4)

- **Powers:** every "by store type" / "by Customer Posting Group" breakdown.
- **Blocked on:** NAV customer master.
- **Consumes:** NAV joined to `customer_key` (= `ust_customer_no` on sales apps,
  `username` on customer apps) via NAV `No_`.
- **Ready when:** NAV lands as a seed/source (e.g. `seed_nav_customers`).

## 6. Page 4 — Sales rep field activity (entire page)

Do **not** build any of these until the masters below land.

- `int_field_activity` — intermediate, grain rep × GPS ping (and rep ×
  customer visit once geofenced).
- `fct_field_activity` — fact, grain rep × visit.
- `mart_field_activity` — reporting (Page 4): store visits per rep/day,
  create+send per rep/day, time gaps between visits, visit duration
  (first→last ping), warehouse-time %.
- `dim_sales_rep` — only if it serves Page 4 (else skip).
- **Consumes / source codes:** `int_events_enriched` GPS-bearing events
  (`01040100` Location-Success + any `has_geo` rows; PDA-A is the only dense GPS
  source ~79%), `04xxxxxx` send, `09010000` create. Geofence = Address master
  lat/lon within 100 m; warehouse % uses UST HQ constant `37.6449, -122.1362`.
- **Blocked on:** Address master (geofence) **and** NAV (salesperson, store
  type). Warehouse-time % and raw field-day window could run on GPS alone, but
  the page's headline (named store visits) needs Address.
- **Ready when:** Address master + NAV land as dbt sources.

---

### Already built (for reference, not deferred)
- Page 2: `int_feature_funnel`, `int_catalog_dwell`, `mart_discovery_navigation`,
  `mart_catalog_dwell`.
- Page 3 (behaviour level): `mart_cart_behaviour`.
