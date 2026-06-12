{{ config(materialized='table') }}

-- Device and system health signals by rep and date.
-- Useful for field ops: identifies reps with persistent GPS, battery,
-- or connectivity issues that may affect app reliability.

with events as (

    select * from {{ ref('int_events_enriched') }}
    where username is not null

)

select
    cast(created_at_utc as date)    as activity_date,
    username,
    sales_code,
    source_code,
    app_name,
    app_platform,
    device_name,

    -- GPS
    sum(case when description_code = '01040100' then 1 else 0 end)
                                    as location_success,
    sum(case when description_code = '01040200' then 1 else 0 end)
                                    as location_fail,
    case
        when sum(case when description_code in ('01040100','01040200') then 1 else 0 end) > 0
        then round(
            cast(sum(case when description_code = '01040100' then 1 else 0 end) as double)
            / sum(case when description_code in ('01040100','01040200') then 1 else 0 end)
            * 100, 1)
    end                             as location_success_pct,

    -- battery
    sum(case when description_code = '01020100' then 1 else 0 end)
                                    as battery_events,
    sum(case when description_code = '01020200' then 1 else 0 end)
                                    as low_battery_events,

    -- network
    sum(case when description_code = '01010100' then 1 else 0 end)
                                    as network_enable,
    sum(case when description_code = '01010200' then 1 else 0 end)
                                    as network_disable,

    -- login issues
    sum(case when description_code = '02040100' then 1 else 0 end)
                                    as timeout_events,

    count(*)                        as total_system_events

from events
where is_system_event = true
  or description_code in ('01040100','01040200')
group by
    cast(created_at_utc as date),
    username,
    sales_code,
    source_code,
    app_name,
    app_platform,
    device_name
