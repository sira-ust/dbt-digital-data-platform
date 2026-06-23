# Event-log dashboard build spec (6 dashboards, `system_event_log` + seeds only)

Scope: the 6 dashboards buildable today without NAV / address masters —
P1 Order journey, P2 Discovery, P3 Cart behaviour, #1 Revenue, #2 Search,
#3 Product funnel. Rep field activity (geofence) and all store-type
segmentation are deferred until the masters land (additive, no rework).

Design principle: **2 facts + the existing decoded/enriched spine, aggregation
pushed to Power BI.** No per-dashboard marts. Because `int_events_enriched`
already denormalises the event dictionary and app-source registry onto every
row, the facts are pre-joined and BI needs few/no separate dimension tables.

> **Build status / amendment.** `fct_orders` and `fct_events` are built and
> validated; the 8 superseded models are retired. **`fct_events` ships as the
> spine only (passthrough columns + raw `response`) — the payload-parsed columns
> in §3 below are NOT built.** Decision: parse per-family fields just-in-time when
> a dashboard actually consumes them (the payload is non-JSON and drifts by app
> version, so parsing ahead of a validating consumer carries fragile regex for no
> one). The cart parse macros in §2 were likewise removed. Treat §2/§3/§5 payload
> parsing as a JIT recipe per dashboard, each with a coverage/drift test. Known
> parsing gotchas to fold in at that point: order payload is **KV not positional**
> (`parse_kv_response`); add-item SKU has 3 shapes incl. `LINE ITEM, <sku>` (no
> qty); `is_success` must be dictionary-driven, not positional (§6 + DQ notes).

---

## 0. Critical correction — order cycle is NOT reconstructable

Verified against real Databricks data (`ust_databricks.mysql.ust_system_event_log`):

| Event | Payload format | ID example | Carries |
|---|---|---|---|
| `04xx` submit-success | **KV** | `increment_id:M000160446` | increment_id, order_source, grand_total, subtotal, total_item_count |
| `09010000` Create Order | **positional** | `JOO002, 032-260128-001` | customer_code, draft doc no. |
| `10.04/05/15` cart edits | positional | (sku only) | sku, qty — **no order id** |

- **Create and submit live in different ID spaces.** Submit ids are `M000…`;
  create ids are `032-…`. Join test: **0 / 10,939 submit ids match any create
  row** on either position. There is no key linking a shopping start to a submit.
- **Adds carry no order id** (the long-standing gap).

**Consequences (correct both the attached plan and the existing repo):**
- `days_to_close`, order-cycle open→close, "pending = adds w/o submit per order",
  and days-in-cycle behaviour segments are **not reconstructable** from this
  source. Drop them (or rebuild on NAV order data later).
- The existing `int_order_cycle` / `fct_order_cycle` are **broken against real
  data**: they parse `increment_id` with `response_part(response,1)` (yields the
  literal `"increment_id:M…"` on KV payloads) and assume a create↔submit join
  that does not exist. They only "pass" today because the DuckDB sample has no
  `04`/`09` rows. **Retire them**; replace with `fct_orders` below.
- What *is* exact: the **submitted order** itself (one `04`-success row =
  increment_id + value + channel + timestamp). That powers #1 Revenue and the
  order-volume half of P1.

---

## 1. Model inventory

| Model | Layer | Action | Purpose |
|---|---|---|---|
| `stg_mysql__system_event_log` | staging (view) | keep | 1:1 source |
| `int_events_decoded` | int (view) | keep | codes, UTC ts, geo, actor, `customer_key`, raw `response` |
| `int_events_enriched` | int (view) | keep | + dictionary + app-source denormalised |
| **`fct_events`** | mart/fact (table) | **new** | wide event fact = enriched + parsed payload columns. Powers P2, P3, #2, #3 |
| **`fct_orders`** | mart/fact (table) | **new** | submit grain (1 row per `04`-success): value + channel. Powers #1, P1 volume |
| `int_order_cycle`, `fct_order_cycle` | int/fact | **retire** | broken premise (see §0) |
| `int_feature_funnel`, `int_catalog_dwell` | int | **fold into `fct_events`** | become BI measures; delete unless reused |
| `mart_cart_behaviour`, `mart_discovery_navigation`, `mart_catalog_dwell`, `mart_order_journey` | mart | **retire** | replaced by BI pages over the 2 facts |
| `dim_*` | mart | **optional** | enriched already denormalises dictionary/app onto the fact; add `dim_category`/`dim_date` only if BI needs them |

Net new dbt objects: **2 facts + 3 small parse macros.** Everything else is reuse or deletion.

---

## 2. New macros (`macros/parse_response.sql`)

`parse_kv_response`, `response_part`, `parse_duration_seconds` already exist.
Add cart sku/qty parsers (robust to the optional leading position field —
`,71116,1` and `73570, 1` both yield sku=second-from-end, qty=last). Regex form
works identically on DuckDB and Databricks:

```sql
{# cart payload: trailing "sku,qty" (optional leading position field) #}
{% macro parse_cart_sku(column) -%}
    nullif(regexp_extract({{ column }}, '([0-9]+)\s*,\s*[0-9]+\s*$', 1), '')
{%- endmacro %}

{% macro parse_cart_qty(column) -%}
    try_cast(regexp_extract({{ column }}, '([0-9]+)\s*$', 1) as integer)
{%- endmacro %}

{# item-detail / enlarge payload: sku is the last comma part ("Fresh & Frozen, 71419" or bare "73162") #}
{% macro parse_trailing_sku(column) -%}
    nullif(trim(regexp_extract({{ column }}, '([^,]+)\s*$', 1)), '')
{%- endmacro %}
```

---

## 3. `fct_events` — the wide event fact

```sql
{{ config(materialized='table') }}

-- fct_events — published event-grain fact for BI. One row per log record.
-- = int_events_enriched (decoded spine + dictionary/app-source denormalised)
-- plus per-family payload columns parsed into typed, nullable fields. A row
-- only populates the columns for its own family; everything else is null.
-- Power BI connects here and aggregates: discovery (P2), cart (P3), search
-- (#2), product funnel (#3). No per-dashboard mart required.

with e as (

    select * from {{ ref('int_events_enriched') }}

)

select
    -- ── grain + context (already denormalised in enriched) ──────────────
    entity_id,
    event_at_utc,
    cast(event_at_utc as date)                                          as event_date,
    customer_key,
    actor_type,
    source_code,
    app_name,
    app_platform,
    app_user_type,
    sales_code,
    username,
    description_code,
    l1_code, l2_code, l3_code, l4_code,
    function_name,
    l1_category_name,
    is_success,
    is_failure,
    latitude,
    longitude,

    -- ── cart / order-ops (Group 10): P3 cart, #3 funnel ─────────────────
    case when l1_code = '10' and l2_code in ('04','05','15')
         then {{ parse_cart_sku('response') }} end                      as cart_sku,
    case when l1_code = '10' and l2_code in ('05','15')
         then {{ parse_cart_qty('response') }} end                      as cart_qty,
    case when l1_code = '10' and l2_code = '05' then 'add'
         when l1_code = '10' and l2_code = '04' then 'remove'
         when l1_code = '10' and l2_code = '15' then 'qty_change' end    as cart_action,

    -- ── pricing override (10.16): margin (bonus, free) ──────────────────
    case when description_code = '10160100'
         then {{ response_part('response', 1) }} end                    as price_item,
    try_cast(case when description_code = '10160100'
         then {{ response_part('response', 2) }} end as double)         as price_original,
    try_cast(case when description_code = '10160100'
         then {{ response_part('response', 3) }} end as double)         as price_modified,

    -- ── item detail / enlarge (14, 15): #3 funnel view stage ────────────
    case when l1_code in ('14','15')
         then {{ parse_trailing_sku('response') }} end                  as viewed_sku,

    -- ── search (Group 12): #2 search ────────────────────────────────────
    case when l1_code = '12'
         then nullif(trim(response), '') end                            as search_query,

    -- ── catalog view (19): P2 dwell ─────────────────────────────────────
    case when description_code = '19010000'
         then {{ parse_kv_response('response', 'category') }} end        as view_category_id,
    try_cast(case when description_code = '19010000'
         then {{ parse_kv_response('response', 'visits_num') }} end as integer) as view_pages,
    try_cast(case when description_code = '19010000'
         then {{ parse_kv_response('response', 'time') }} end as integer)       as view_dwell_seconds,

    -- ── feature clicks (Group 18): P2 funnel + exploration ──────────────
    case when l1_code = '18'
         then nullif(trim(response), '') end                            as feature_title,

    response
from e
```

P2's feature funnel (click Group 18 → add Group 10.5) and exploration depth
(`promo_to_bottom` etc.) are **BI measures** over `cart_action`, `l1_code`,
`description_code` — no `int_feature_funnel` / `int_catalog_dwell` needed.
Category name resolves via `dim_category` (or a BI lookup) on `view_category_id`.

---

## 4. `fct_orders` — submit-grain order fact (exact)

```sql
{{ config(materialized='table') }}

-- fct_orders — one row per SUBMITTED order (Group 04 success). The submit
-- payload is KV: increment_id, order_source, grand_total, subtotal,
-- total_item_count. This is exact and self-contained — NO join to Create
-- Order (different ID space; see build-spec §0). Powers #1 Revenue/AOV and
-- the order-volume metrics on P1. order_source is the coarse channel
-- (WEB / APP / PDA), distinct from source_code.

with submits as (

    select * from {{ ref('int_events_enriched') }}
    where l1_code = '04' and is_success
      and response rlike 'increment_id:'

),

parsed as (

    select
        {{ parse_kv_response('response', 'increment_id') }}             as increment_id,
        customer_key,
        actor_type,
        source_code,
        app_name,
        sales_code,
        username,
        event_at_utc                                                    as submitted_at,
        upper({{ parse_kv_response('response', 'order_source') }})      as order_channel,
        try_cast({{ parse_kv_response('response', 'grand_total') }} as double)      as grand_total,
        try_cast({{ parse_kv_response('response', 'subtotal') }} as double)         as subtotal,
        try_cast({{ parse_kv_response('response', 'total_item_count') }} as integer) as total_item_count,
        description_code
    from submits

),

-- a resubmit logs the same increment_id more than once; keep the last
deduped as (

    select *,
        row_number() over (partition by increment_id order by submitted_at desc) as _rn
    from parsed
    where increment_id is not null and increment_id <> ''

)

select
    increment_id,
    customer_key,
    actor_type,
    source_code,
    app_name,
    sales_code,
    username,
    submitted_at,
    cast(submitted_at as date)                                          as submitted_date,
    order_channel,
    grand_total,
    subtotal,
    grand_total - subtotal                                              as freight_and_adj,
    total_item_count
from deduped
where _rn = 1
```

---

## 5. Dashboard → fact → BI aggregation

| Dashboard | Reads | Built in BI as |
|---|---|---|
| **#1 Revenue / AOV** | `fct_orders` | sum(grand_total), avg(grand_total)=AOV, sum(total_item_count), by `order_channel` / `submitted_date` |
| **P1 Order journey** (reduced) | `fct_orders` | submitted-order volume & value trend, channel mix. ⚠️ days-to-close / pending / segments **removed** (§0) |
| **P2 Discovery** | `fct_events` | feature funnel = clicks (`l1='18'`) vs adds (`cart_action='add'`) per feature; category dwell = avg(`view_dwell_seconds`) by `view_category_id`; exploration depth = scroll-to-bottom codes ÷ page entries |
| **P3 Cart behaviour** (customer grain) | `fct_events` | per `customer_key`: count adds/removes/qty by `cart_action`; churn = removes÷adds; distinct `cart_sku` added |
| **#2 Search** | `fct_events` | top `search_query`, volume by `app_name`, query→add behavioural link via `customer_key` |
| **#3 Product funnel** | `fct_events` | per sku: views (`viewed_sku`) → adds (`cart_sku`,`cart_action='add'`) → ordered (line-level not in `04`; use add-as-proxy) |
| *(bonus)* **Margin/pricing** | `fct_events` | discount depth = `price_original - price_modified`, by sku/rep (84,772 events) |

---

## 6. Validation before shipping

1. `fct_orders`: row count ≈ distinct `04`-success increment_ids (~10.9k); check
   `grand_total >= subtotal`, no null increment_id, channel ∈ {WEB,APP,PDA,…}.
2. `fct_events`: `cart_qty`/`cart_sku` non-null rate on Group 10.05 (catch the
   `,sku,qty` vs `sku,qty` variants); `search_query` non-empty on Group 12.
3. Confirm `int_events_decoded` already quarantines the injection-probe `source`
   junk (it filters to `seed_app_sources` — verified) so `fct_events` is clean.
4. Window: event log starts 2026-01-22 (~5 months) — no YoY.

## 7. Later, additively (NAV / address)

- `dim_customer` (NAV) joins to both facts on `customer_key` → re-enables
  store-type slicers on P1/P3. No fact change.
- Geofence branch (`int_field_pings` → `fct_field_activity`) is independent →
  unlocks P4. No fact change.
