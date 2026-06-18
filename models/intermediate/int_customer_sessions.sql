with sessions as (

    select * from {{ ref('stg_mysql__tracking_report') }}

),

events as (

    select * from {{ ref('stg_mysql__tracking_report_event') }}

)

select
    s.entity_id                                 as session_id,
    s.customer_id,
    s.customer_name,
    s.device_model,
    s.app_version,
    s.start_time                                as session_start,
    s.end_time                                  as session_end,
    s.total_events,
    e.entity_id                                 as event_id,
    e.page,
    e.event_type,
    e.event_type_code,
    e.title,
    e.sku,
    e.qty,
    e.keyword,
    e.duration_seconds,
    e.start_time                                as event_start
from sessions s
left join events e
    on e.tracking_report_id = s.entity_id
