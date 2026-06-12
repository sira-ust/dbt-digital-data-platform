-- audit_event_record_errors — row-level DQ violations (one row per record × rule).
-- Joins staging to seed reference data for dictionary-driven checks.

{{ config(materialized='table') }}

with events as (

    select * from {{ ref('int_events_enriched') }}

),

categories as (

    select * from {{ ref('seed_categories') }}

),

unknown_event_code as (

    select
        entity_id,
        'unknown_event_code' as error_type,
        'error' as severity,
        'code not in seed_event_codes' as error_detail,
        description_code,
        source_code,
        created_at_utc,
        response
    from events
    where function_name is null

),

unknown_source_code as (

    select
        entity_id,
        'unknown_source_code' as error_type,
        'error' as severity,
        'source not in seed_app_sources' as error_detail,
        description_code,
        source_code,
        created_at_utc,
        response
    from events
    where app_name is null

),

unexpected_payload as (

    select
        entity_id,
        'unexpected_payload' as error_type,
        'warn' as severity,
        'dictionary expects no payload but response is non-empty'
            as error_detail,
        description_code,
        source_code,
        created_at_utc,
        response
    from events
    where expected_payload_format = 'none'
      and response is not null
      and trim(response) <> ''

),

missing_payload as (

    select
        entity_id,
        'missing_payload' as error_type,
        'warn' as severity,
        'dictionary expects format ' || expected_payload_format
            || ' but response is empty' as error_detail,
        description_code,
        source_code,
        created_at_utc,
        response
    from events
    where expected_payload_format is not null
      and expected_payload_format not in ('none', 'bare_value', 'fail_marker')
      and (response is null or trim(response) = '')

),

missing_event_time as (

    select
        entity_id,
        'missing_event_time' as error_type,
        'warn' as severity,
        'device event_time absent or unparseable' as error_detail,
        description_code,
        source_code,
        created_at_utc,
        response
    from events
    where event_at_utc is null

),

unknown_category as (

    select
        e.entity_id,
        'unknown_category' as error_type,
        'warn' as severity,
        'kv category id ' || coalesce({{ parse_kv_response('e.response', 'category') }}, '?')
            || ' not in seed_categories' as error_detail,
        e.description_code,
        e.source_code,
        e.created_at_utc,
        e.response
    from events e
    left join categories c
        on {{ parse_kv_response('e.response', 'category') }} = c.category_id
    where e.description_code = '19010000'
      and c.category_id is null

),

unioned as (

    select * from unknown_event_code
    union all
    select * from unknown_source_code
    union all
    select * from unexpected_payload
    union all
    select * from missing_payload
    union all
    select * from missing_event_time
    union all
    select * from unknown_category

)

select
    entity_id,
    error_type,
    severity,
    error_detail,
    description_code,
    source_code,
    created_at_utc,
    response
from unioned
order by entity_id, error_type
