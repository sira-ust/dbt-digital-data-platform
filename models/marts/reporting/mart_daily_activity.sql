{{ config(materialized='table') }}

with events as (

    select * from {{ ref('int_events_enriched') }}
    where username is not null

)

select
    cast(created_at_utc as date)        as activity_date,
    source_code,
    app_name,
    app_platform,
    app_user_type,

    count(*)                            as total_events,
    count(distinct username)            as active_users,

    -- system health signals
    sum(case when description_code = '01040100' then 1 else 0 end)
                                        as location_success,
    sum(case when description_code = '01040200' then 1 else 0 end)
                                        as location_fail,
    sum(case when description_code = '01020200' then 1 else 0 end)
                                        as low_battery_events,
    sum(case when description_code = '01010100' then 1 else 0 end)
                                        as network_enable,
    sum(case when description_code = '01010200' then 1 else 0 end)
                                        as network_disable,

    -- engagement signals
    sum(case when l1_category_name = 'Search' then 1 else 0 end)
                                        as search_events,
    sum(case when l1_category_name = 'Item Image Enlarge' then 1 else 0 end)
                                        as item_enlarge_events,
    sum(case when l1_category_name = 'Order Operations' then 1 else 0 end)
                                        as order_operation_events,
    sum(case when l1_category_name = 'Activity (Customer Interactions)' then 1 else 0 end)
                                        as customer_interaction_events

from events
group by
    cast(created_at_utc as date),
    source_code,
    app_name,
    app_platform,
    app_user_type
