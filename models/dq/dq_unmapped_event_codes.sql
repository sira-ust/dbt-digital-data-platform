-- DQ audit: event codes present in the real data but absent from the event
-- dictionary (seed_event_codes). These rows pass the source filter (they are
-- genuine app events in int_events_decoded), but their description_code has no
-- dictionary entry, so int_events_enriched / fct_events return null
-- function_name + l1_category_name for them. Captured here so the dictionary
-- gap stays visible and seed_event_codes can be extended from the app team's
-- authoritative code list. The relationships test on
-- int_events_decoded.description_code is the tripwire; this is the detail.
--
-- is_well_formed_code separates true dictionary gaps (8-digit codes the app
-- emits but the seed lacks) from malformed/junk codes. One row per unmapped
-- description_code, most frequent first.

with events as (

    select * from {{ ref('int_events_decoded') }}

),

dictionary as (

    select description_code from {{ ref('seed_event_codes') }}

),

unmapped as (

    select e.*
    from events as e
    left join dictionary as d
        on e.description_code = d.description_code
    where d.description_code is null

)

select
    description_code,
    -- portable all-digits-and-8-long check (no engine-specific regex)
    (length(description_code) = 8
        and try_cast(description_code as bigint) is not null)          as is_well_formed_code,
    substr(description_code, 1, 2)                                     as l1_code,
    count(*)                                                           as event_count,
    count(distinct source_code)                                       as distinct_sources,
    min(source_code)                                                  as example_source,
    min(created_at_utc)                                               as first_seen_utc,
    max(created_at_utc)                                               as last_seen_utc
from unmapped
group by
    description_code,
    (length(description_code) = 8
        and try_cast(description_code as bigint) is not null),
    substr(description_code, 1, 2)
order by event_count desc
