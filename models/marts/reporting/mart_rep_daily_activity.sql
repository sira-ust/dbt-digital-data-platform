with events as (

    select * from {{ ref('int_rep_activity_events') }}

),

daily as (

    select
        username,
        sales_code,
        activity_date,
        max(device_model)                                               as device_model,
        max(app_version)                                                as app_version,
        count(distinct session_id)                                      as sessions,
        count(*)                                                        as total_events,
        count(
            distinct case when customer is not null
                           and customer != username then customer end
        )                                                               as customers_visited,
        count(distinct sku)                                             as unique_skus,
        count(case when sku is not null then 1 end)                     as sku_events,
        count(case when location is not null then 1 end)                as gps_pings,
        count(case when is_login = 1 then 1 end)                        as login_events,
        min(begin_time)                                                 as first_event_at,
        max(begin_time)                                                 as last_event_at,
        min(battery)                                                    as min_battery,
        round(avg(battery), 1)                                          as avg_battery
    from events
    where activity_date is not null
    group by 1, 2, 3

)

select
    username,
    sales_code,
    activity_date,
    device_model,
    app_version,
    sessions,
    total_events,
    customers_visited,
    unique_skus,
    sku_events,
    gps_pings,
    login_events,
    first_event_at,
    last_event_at,
    {{ dbt.datediff('first_event_at', 'last_event_at', 'minute') }}     as active_minutes,
    min_battery,
    avg_battery
from daily
