-- Login events (codes 0203xx). No structured payload; failures may carry
-- a bare 'Fail' marker in response.

with events as (

    select * from {{ ref('int_events_enriched') }}
    where l1_code = '02' and l2_code = '03'

)

select
    entity_id,
    description_code,
    function_name,
    is_success,
    is_failure,
    source_code,
    app_name,
    app_platform,
    actor_type,
    username,
    customer_key,
    sales_code,
    device_name,
    app_version,
    latitude,
    longitude,
    created_at_utc,
    event_at_utc

from events
