{{ config(materialized='table') }}

with events as (

    select * from {{ ref('int_user_activity_enriched') }}
    where username is not null

)

select
    cast(started_at as date)                                                as activity_date,
    username,
    sales_code,

    -- session metrics
    count(distinct session_entity_id)                                       as total_sessions,

    -- event metrics
    count(*)                                                                as total_events,
    count(*) filter (where is_login = true)                                 as login_events,
    count(*) filter (where is_done = true)                                  as completed_events,
    count(*) filter (where is_done = false)                                 as failed_events,

    -- customer coverage
    count(distinct case when customer_id is not null then customer_id end)  as unique_customers_visited,

    -- product activity
    count(distinct case when sku is not null then sku end)                  as unique_skus_interacted,

    -- device health
    avg(battery_pct) filter (where battery_pct is not null)                 as avg_battery_pct,
    min(battery_pct) filter (where battery_pct is not null)                 as min_battery_pct,
    count(*) filter (where is_wifi = true)                                  as wifi_events,
    count(*) filter (where is_wifi = false)                                 as cellular_events,

    -- device context (most recently seen values)
    max_by(device_model, started_at)                                        as device_model,
    max_by(session_app_version, started_at)                                 as app_version

from events
group by
    cast(started_at as date),
    username,
    sales_code
