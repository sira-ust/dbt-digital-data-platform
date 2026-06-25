-- All events enriched with the event dictionary (seed_event_codes) and the
-- app-source registry. Event grain — one row per log record.
--
-- Reads the decoded spine (int_events_decoded); decoding/parsing lives there,
-- this model adds the dictionary + app-source joins and applies quality filters:
-- sales_code exclusion, username exclusion via seed_system_accounts, event_at_utc not null.
-- Foundation for analytics: per-family int_* parsers and fct_* facts select
-- from here. Aggregations belong in mart_* (not in intermediate).

with events as (

    select * from {{ ref('int_events_decoded') }}

),

codes as (

    select * from {{ ref('seed_event_codes') }}

),

apps as (

    select * from {{ ref('seed_app_sources') }}

),

system_accounts as (

    select username from {{ ref('seed_system_accounts') }}

)

select
    e.*,
    c.function_name,
    c.l1_category_name,
    c.payload_format                as expected_payload_format,
    c.has_geo                       as expects_geo,
    c.is_system_event,
    c.event_type,
    c.log_level,
    a.app_name,
    a.user_type                     as app_user_type,
    a.platform                      as app_platform

from events as e
left join codes as c
    on e.description_code = c.description_code
left join apps as a
    on e.source_code = a.source_code

where e.sales_code not in ('000')
  and (e.username is null or e.username not in (select username from system_accounts))
  and e.event_at_utc is not null
