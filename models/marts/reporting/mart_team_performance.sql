{{ config(materialized='table') }}

with events as (

    select * from {{ ref('int_events_enriched') }}
    where actor_type = 'sales'
      and username is not null
      and sales_code is not null

)

select
    sales_code,
    username,
    source_code,
    app_name,
    app_platform,

    count(distinct cast(created_at_utc as date))    as active_days,
    count(*)                                        as total_events,
    min(cast(created_at_utc as date))               as first_seen_date,
    max(cast(created_at_utc as date))               as last_active_date,
    count(distinct device_name)                     as distinct_devices,
    count(distinct customer_key)                    as distinct_customers_touched,

    -- engagement breakdown
    sum(case when l1_category_name = 'Search' then 1 else 0 end)
                                                    as search_events,
    sum(case when l1_category_name = 'Item Image Enlarge' then 1 else 0 end)
                                                    as item_enlarge_events,
    sum(case when l1_category_name = 'Order Operations' then 1 else 0 end)
                                                    as order_operation_events,
    sum(case when l1_category_name = 'Activity (Customer Interactions)' then 1 else 0 end)
                                                    as customer_interaction_events,

    -- system events (noise filter — useful for device health)
    sum(case when description_code = '01020200' then 1 else 0 end)
                                                    as low_battery_events,
    sum(case when description_code = '01040200' then 1 else 0 end)
                                                    as location_fail_events

from events
group by
    sales_code,
    username,
    source_code,
    app_name,
    app_platform
