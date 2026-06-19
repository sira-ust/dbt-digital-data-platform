-- Quarantine: system_event_log rows whose `source` is not a known app source
-- code (seed_app_sources). In the live data these are scanner/bot payloads —
-- SQL injection, XSS, path traversal, and SSRF probes — that the Web endpoint
-- logged into the source column. They are excluded from int_events_decoded
-- (the analytics spine) and captured here for inspection / security review.
-- One row per quarantined event.

with events as (

    select * from {{ ref('stg_mysql__system_event_log') }}

),

valid_sources as (

    select source_code from {{ ref('seed_app_sources') }}

)

select
    entity_id,
    source,
    username,
    ust_customer_no,
    location,
    event_time,
    description_code,
    response,
    device_name,
    created_at,
    updated_at
from events
where source is null
   or source not in (select source_code from valid_sources)
