-- int_item_demand_daily — app-side item demand, one row per sku x day x
-- source system. The single owner of SKU extraction from event payloads:
-- every downstream model that needs "which item" reads the clean sku column
-- from here instead of re-parsing response strings.
--
-- Two payload shapes carry a SKU (seed_event_codes.payload_format):
--   positional  cart events (add/remove/qty-change): "sku,qty[,category]"
--               -> sku = part 1, qty = part 2
--   sku         item-detail / image-enlarge (and BLE) events: response IS
--               the sku
--
-- Only payload skus matching the WMS item-number shape (3-8 digits) are
-- kept — the rest is scanner junk / app-version drift, visible in
-- dq_unmatched_demand_skus (which also catches well-formed skus that match
-- no prtmst item). Verified 2026-07-13: app sku values = jdawms prtnum
-- (99.9% on the clean tracking columns, ~89% of parsed cart payloads).
--
-- source_system is constant 'event_log' today; the legacy tracking tables
-- (mysql.ust_tracking_report_event, history back to 2023-09) union in here
-- with their own label if pre-2026 history is ever needed.
--
-- Materialized as a VIEW (overrides the intermediate table default): it is
-- a thin projection over int_events_enriched (already a table) and is read
-- once per mart build — storing it would cost DBU for no reuse win.

{{ config(materialized='view') }}

with demand_events as (

    select
        cast({{ dbt.date_trunc('day', 'event_at_utc') }} as date)       as activity_date,
        customer_key,
        actor_type,
        feature_name,
        is_add,
        is_remove,
        is_qty_change,
        case
            when expected_payload_format = 'positional'
                then {{ response_part('response', 1) }}
            when expected_payload_format = 'sku'
                then nullif(trim(response), '')
        end                                                             as raw_sku,
        case
            when expected_payload_format = 'positional' and is_add
                then try_cast({{ response_part('response', 2) }} as int)
        end                                                             as add_qty
    from {{ ref('int_events_enriched') }}
    where event_at_utc is not null
      -- event_at_utc is device time: clamp device-clock skew (dates before
      -- the log went live or in the future) so daily demand stays plausible
      and event_at_utc >= cast('{{ var("event_log_go_live_date") }}' as timestamp)
      and event_at_utc <= {{ dbt.current_timestamp() }}
      and (
            is_add or is_remove or is_qty_change
            or feature_name in ('item_detail', 'image_enlarge')
          )

),

valid as (

    -- keep only skus shaped like a WMS item number (prtnum: digits, e.g.
    -- 54309); free-text / malformed payloads drop here
    select *
    from demand_events
    where nullif(regexp_extract(raw_sku, '^[0-9]{3,8}$', 0), '') is not null

)

select
    activity_date,
    raw_sku                                                             as sku,
    'event_log'                                                         as source_system,
    sum(case when feature_name = 'item_detail'   then 1 else 0 end)    as item_detail_views,
    sum(case when feature_name = 'image_enlarge' then 1 else 0 end)    as image_enlarge_views,
    sum(case when is_add        then 1 else 0 end)                     as cart_adds,
    sum(case when is_remove     then 1 else 0 end)                     as cart_removes,
    sum(case when is_qty_change then 1 else 0 end)                     as cart_qty_changes,
    sum(case when is_add        then add_qty else 0 end)               as cart_add_qty,
    count(distinct customer_key)                                        as distinct_customers,
    count(distinct case when actor_type = 'customer'
                        then customer_key end)                          as distinct_self_customers
from valid
group by 1, 2, 3
