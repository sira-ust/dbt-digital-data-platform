{{ config(materialized='table') }}

-- fct_orders — one row per SUBMITTED order (Group 04 success). The submit
-- payload is KV: "increment_id:M…, order_source:WEB, grand_total:…,
-- subtotal:…, total_item_count:…". This fact is EXACT and self-contained —
-- it does NOT join to Create Order (09): submit ids are M-prefixed while
-- create ids are 032-prefixed and the two ID spaces never match (verified:
-- 0/10,939 overlap — see docs/event-log-dashboard-build-spec.md §0). Order
-- shopping-cycle / days-to-close is therefore not reconstructable from this
-- source; this fact carries the submitted-order value + channel only.
--
-- Powers #1 Revenue/AOV and the order-volume metrics on P1. order_channel
-- (WEB / APP / PDA) is the coarse payload channel, distinct from source_code.

with submits as (

    -- The rich KV payload (increment_id:…, grand_total:…) appears ONLY on
    -- submit-success events, so matching it isolates them directly. We do NOT
    -- use is_success: the order family encodes success at L3 (positions 5-6),
    -- but int_events_decoded.is_success reads L4 — wrong for this family.
    -- Customer-app submits (04050100) log only a bare value (no KV / no value),
    -- so they are intentionally excluded; revenue is captured for the WEB/APP/PDA
    -- server-side order receipts (04010100-04040100) that carry order_source.
    select * from {{ ref('int_events_enriched') }}
    where l1_code = '04'
      and response like '%increment_id:%'

),

parsed as (

    select
        {{ parse_kv_response('response', 'increment_id') }}                          as increment_id,
        customer_key,
        actor_type,
        source_code,
        app_name,
        sales_code,
        username,
        event_at_utc                                                                 as submitted_at,
        upper({{ parse_kv_response('response', 'order_source') }})                   as order_channel,
        try_cast({{ parse_kv_response('response', 'grand_total') }} as double)        as grand_total,
        try_cast({{ parse_kv_response('response', 'subtotal') }} as double)           as subtotal,
        try_cast({{ parse_kv_response('response', 'total_item_count') }} as integer)  as total_item_count
    from submits

),

filtered as (

    select * from parsed
    where increment_id is not null and increment_id <> ''

),

-- a resubmit logs the same increment_id more than once; keep the latest
numbered as (

    select
        *,
        row_number() over (partition by increment_id order by submitted_at desc) as _rn
    from filtered

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
from numbered
where _rn = 1
