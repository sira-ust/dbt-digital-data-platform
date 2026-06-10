-- Download / sync events (L1 = 03). Successes carry a duration payload
-- ('Time:42', seconds); failures carry 'Fail' or empty.

with events as (

    select * from {{ ref('int_events_enriched') }}
    where l1_code = '03'

)

select
    entity_id,
    description_code,
    function_name,
    l2_code as download_type_code,
    is_success,
    is_failure,
    source_code,
    app_name,
    app_platform,
    app_version,
    device_name,
    created_at_utc,
    event_at_utc,

    -- duration only present on successes
    {{ parse_duration_seconds('response') }} as duration_s

from events
