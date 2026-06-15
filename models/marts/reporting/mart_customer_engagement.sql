{{ config(materialized='table') }}

with events as (

    select * from {{ ref('int_customer_tracking_enriched') }}

)

select
    customer_id,
    max(customer_name)                                                  as customer_name,

    -- session metrics
    count(distinct session_entity_id)                                   as total_sessions,
    min(session_started_at)                                             as first_session_at,
    max(session_started_at)                                             as last_session_at,
    count(distinct cast(session_started_at as date))                    as active_days,

    -- event metrics
    count(*)                                                            as total_events,
    avg(duration_seconds)                                               as avg_event_duration_seconds,

    -- page metrics
    count(distinct page)                                                as unique_pages_visited,

    -- product interactions
    count(distinct case when sku is not null then sku end)              as unique_skus_viewed,
    sum(case when qty is not null and qty > 0 then qty end)             as total_qty_interacted,
    count(*) filter (where lower(page) = 'cart')                        as cart_page_events,

    -- device context (most recently seen values)
    max_by(device_model, started_at)                                    as device_model,
    max_by(app_version, started_at)                                     as app_version

from events
group by customer_id
