{{ config(materialized='table') }}

-- Daily per-rep activity broken down by event category.
-- Grain: activity_date x username x source_code x l1_category_name.
-- Use this in Power BI for stacked bar / drill-down visuals showing
-- what each rep did each day by category.

with events as (

    select * from {{ ref('int_events_enriched') }}
    where actor_type = 'sales'
      and username is not null
      and sales_code is not null

)

select
    cast(created_at_utc as date)                        as activity_date,
    username,
    sales_code,
    source_code,
    app_name,
    app_platform,
    coalesce(l1_category_name, 'Uncategorised')         as event_category,
    is_system_event,

    count(*)                                            as event_count,
    count(distinct device_name)                         as distinct_devices,
    count(distinct customer_key)                        as distinct_customers_touched

from events
group by
    cast(created_at_utc as date),
    username,
    sales_code,
    source_code,
    app_name,
    app_platform,
    coalesce(l1_category_name, 'Uncategorised'),
    is_system_event
