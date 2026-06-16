-- int_events_decoded — the decode/parse layer for the system event log.
-- Reads lossless staging (stg_mysql__system_event_log) and applies everything
-- that is NOT a 1:1 source map: rename to analytics names, split the 8-digit
-- description_code into L1-L4, derive success/failure, convert device-local
-- event_time and server PST timestamps to UTC, parse the location string into
-- lat/lon, and decode the app source into actor_type + a unified customer_key.
--
-- This is the workhorse spine: int_events_enriched (dictionary + app-source
-- join) and every downstream fact/mart read from here, never from staging.
-- Payload (`response`) is carried through raw and parsed per-family downstream.

with events as (

    select * from {{ ref('stg_mysql__system_event_log') }}

)

select
    -- ── identifiers ────────────────────────────────────────────────────
    entity_id,
    nullif(sales_code, '')                                              as sales_code,
    nullif(username, '')                                                as username,
    nullif(ust_customer_no, '')                                         as ust_customer_no,
    nullif(device_name, '')                                             as device_name,
    cast(source as {{ dbt.type_string() }})                             as source_code,
    nullif(version, '')                                                 as app_version,

    -- ── event code: 8-digit hierarchical split ─────────────────────────
    description_code,
    substr(description_code, 1, 2)                                      as l1_code,
    substr(description_code, 3, 2)                                      as l2_code,
    substr(description_code, 5, 2)                                      as l3_code,
    substr(description_code, 7, 2)                                      as l4_code,
    substr(description_code, 7, 2) = '01'                               as is_success,
    substr(description_code, 7, 2) = '02'                               as is_failure,

    -- ── timestamps ─────────────────────────────────────────────────────
    -- event_time is device LOCAL; convert to UTC via the row timezone offset.
    {{ add_hours(
        'event_time',
        '-coalesce(' ~ tz_offset_hours('timezone') ~ ', 0)'
    ) }}                                                                as event_at_utc,
    timezone                                                            as device_timezone,
    -- created_at / updated_at are server PST (UTC-8, no DST): constant +8h.
    {{ add_hours('created_at', 8) }}                                   as created_at_utc,
    {{ add_hours('updated_at', 8) }}                                   as updated_at_utc,
    {{ epoch_millis_to_ts('event_id') }}                               as event_id_at_utc,

    -- ── geo: "lat,lon" or empty ─────────────────────────────────────────
    try_cast({{ response_part('location', 1) }} as double)              as latitude,
    try_cast({{ response_part('location', 2) }} as double)              as longitude,

    -- ── actor: sales apps act on behalf of a customer; customer apps are
    --    the customer themselves (username = customer account number) ─────
    case
        when source in ('PDA-A', 'CatalogFS-I', 'CatalogFS-A') then 'sales'
        else 'customer'
    end                                                                 as actor_type,
    case
        when source in ('PDA-A', 'CatalogFS-I', 'CatalogFS-A')
            then nullif(ust_customer_no, '')
        else nullif(username, '')
    end                                                                 as customer_key,

    -- ── payload (parsed per-family downstream) ──────────────────────────
    response

from events
