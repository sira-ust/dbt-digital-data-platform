-- int_events_decoded — the decode/parse layer for the system event log.
-- Reads lossless staging (stg_mysql__system_event_log) and applies everything
-- that is NOT a 1:1 source map: rename to analytics names, split the 8-digit
-- description_code into L1-L4, convert device-local event_time and server PST
-- timestamps to UTC, parse the location string into lat/lon, and decode the app
-- source into actor_type + a unified customer_key.
--
-- NOTE: success/failure is intentionally NOT derived here. The outcome marker
-- sits at different segments by family (L4 for some, L3 for orders/location/
-- downloads) and EVENT codes reuse '01' as a page variant — positional logic is
-- wrong and dictionary-driven logic isn't this layer's job. The raw L1-L4 splits
-- are passed through losslessly; a consumer applies correct outcome logic JIT.
--
-- This is the workhorse spine: int_events_enriched (dictionary + app-source
-- join) and every downstream fact/mart read from here, never from staging.
-- Payload (`response`) is carried through raw and parsed per-family downstream.

with events as (

    select * from {{ ref('stg_mysql__system_event_log') }}

),

valid_sources as (

    -- canonical app source registry. Anything else is scanner/bot noise logged
    -- into the source column (SQLi/XSS/path-traversal probes against the Web
    -- endpoint); those rows are quarantined in dq_quarantine_invalid_source and
    -- excluded here so the analytics spine only contains real app events.
    select source_code from {{ ref('seed_app_sources') }}

),

-- ── DEDUPE the batch re-upload ──────────────────────────────────────────
-- The PDA re-sends a batch it has already sent, and every pass INSERTS with
-- fresh entity_ids, so staging's dedupe (keyed on entity_id, the source PK)
-- cannot see it. Left alone this inflates every event count downstream.
--
-- Measured 2026-08-24 on the whole event fact: 331,844 surplus cart rows of
-- 1,382,243 (24%), and it is not cart-specific -- L1 11 Filtering is 70%
-- duplicated, 19 Catalog View 54%, 10 Order Operations 23%. Worst single action
-- was stored 36 times. A concrete example: SAI023 / 2026-04-13 / SKU '37343, 1'
-- stored 3x as entity_id 1727897 / 1728112 / 1728282, identical event_time and
-- payload, uploaded 20 and 26 seconds apart.
--
-- BOTH duplicate shapes are the same artifact, so both are deduped:
--   separate uploads   copies carry different created_at_utc (200,289 groups)
--   one upload         one pass wrote the batch twice, appearing as TWO
--                      contiguous entity_id runs holding the same sequence
--                      (71,045 groups; verified 018 / ASI163 / 2026-02-03,
--                      entity_ids 44059-44064 and 44330-44335 -- six distinct
--                      SKUs, each stored exactly twice)
--
-- The business key is what the app actually did: one actor, one customer, one
-- instant, one code, one payload. Lowest entity_id wins so the surviving row is
-- the first-landed one and the choice is stable across rebuilds.
--
-- NOT deduped on event_at_utc-only or without response: two different SKUs added
-- in the same second are two real adds, and collapsing them would delete work.
deduped as (

    select *
    from (
        select
            *,
            row_number() over (
                partition by
                    sales_code, ust_customer_no, source, event_time,
                    description_code, response
                order by entity_id
            ) as _dup_rn
        from events
    ) as d
    where _dup_rn = 1

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

    -- ── timestamps ─────────────────────────────────────────────────────
    -- event_time is epoch (live MySQL, already UTC) OR a device-LOCAL datetime
    -- string (local JSON sample, needs the tz offset). event_time_to_utc
    -- branches on the format; applying the offset to both was a double
    -- conversion that skewed the whole warehouse by up to 9h until 2026-08-13.
    {{ event_time_to_utc('event_time', 'timezone') }}                   as event_at_utc,
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
            then coalesce(
                nullif(ust_customer_no, ''),
                {{ parse_kv_response('response', 'ust_customer_no') }}
            )
        else nullif(username, '')
    end                                                                 as customer_key,

    -- ── payload (parsed per-family downstream) ──────────────────────────
    response

from deduped
where source in (select source_code from valid_sources)
