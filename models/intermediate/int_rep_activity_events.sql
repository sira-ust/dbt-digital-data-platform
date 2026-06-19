with events as (

    select * from {{ ref('stg_mysql__user_activity_report_event') }}

),

sessions as (

    select
        entity_id,
        device_model,
        app_version
    from {{ ref('stg_mysql__user_activity_report') }}

),

reps as (

    -- salesperson_code is the rep territory code; the event table no longer
    -- carries sales_code, so resolve it from admin_users via the login account.
    -- Aggregated to one row per username to guard against fan-out on the join.
    select
        username,
        max(salesperson_code) as salesperson_code
    from {{ ref('stg_mysql__admin_users') }}
    where username is not null
    group by username

)

select
    e.entity_id,
    e.user_activity_report_id           as session_id,
    e.username,
    r.salesperson_code                  as sales_code,
    e.activity_type,
    e.customer,
    e.begin_time,
    e.end_time,
    e.location,
    e.sku,
    e.qty,
    e.visits_num,
    e.keyword,
    e.category,
    e.response,
    e.battery,
    e.is_wifi,
    e.is_done,
    e.is_login,
    e.timezone,
    s.app_version,
    s.device_model,
    cast(e.begin_time as date)           as activity_date
from events e
left join sessions s
    on s.entity_id = e.user_activity_report_id
left join reps r
    on r.username = e.username
