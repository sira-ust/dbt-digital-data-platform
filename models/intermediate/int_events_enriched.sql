-- All events enriched with the event dictionary (seed_event_codes) and the
-- app-source registry. Base relation for the per-family models and marts.

with events as (

    select * from {{ ref('stg_mysql__system_events') }}

),

codes as (

    select * from {{ ref('seed_event_codes') }}

),

apps as (

    select * from {{ ref('seed_app_sources') }}

)

select
    e.*,
    c.function_name,
    c.l1_category_name,
    c.payload_format as expected_payload_format,
    c.has_geo as expects_geo,
    c.is_system_event,
    c.event_type,
    c.log_level,
    a.app_name,
    a.user_type as app_user_type,
    a.platform as app_platform

from events as e
left join codes as c
    on e.description_code = c.description_code
left join apps as a
    on e.source_code = a.source_code
