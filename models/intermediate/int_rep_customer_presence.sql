{{ config(materialized='table') }}

-- int_rep_customer_presence — where a rep physically was, from GPS.
-- One row per rep x customer x VISIT (a rep can visit the same customer twice
-- in a day; that is two rows).
--
-- Derived INDEPENDENTLY of app activity, on purpose. A visit that produced no
-- typing has no activity row to hang off, so joining GPS onto activity would
-- make exactly that case invisible — and it is the case the business most wants
-- counted (relationship calls, delivery issues, collections). Presence is built
-- first; the mart joins activity onto it.
--
-- Each step below exists because of a measured failure, not a hypothetical:
--
--  1. SPLIT PER DEVICE. Reps carry a median of 3 devices (max 5). Sorting all
--     of a rep's fixes into one timeline makes them teleport: 10.7% of
--     consecutive hops imply >80mph and 97% of those are a device change.
--  2. DROP IMPOSSIBLE HOPS inside a device track (> var presence_max_mph).
--  3. EXCLUDE THE OFFICE. The company address is in the customer table and
--     would otherwise be every rep's most-visited "customer" — rep 025 spent
--     236 minutes there on 2026-08-11.
--  4. MATCH each fix to the nearest customer within var presence_geofence_metres.
--  5. GROUP consecutive fixes into visits, ending on var presence_visit_gap_minutes.
--     NOT first-to-last across the day: min->max lumped two separate stops plus
--     lunch into one 187-minute "visit" during prototyping.
--  6. DROP visits under var presence_min_dwell_minutes — driving past is not a visit.
--  7. MERGE overlapping visits ACROSS devices. Step 1 stops the teleporting but
--     then logs the same visit once per device (DAI003 appeared twice).
--
-- AMBIGUITY IS PUBLISHED, NOT HIDDEN. 21.2% of customers have another customer
-- within 100m and 10.3% within 25m — inside GPS error, where "nearest" is a coin
-- flip rather than a measurement. is_ambiguous carries that so a consumer can
-- exclude uncertain visits instead of the model silently choosing.
--
-- Full-rebuild table: visit boundaries shift as fixes land.

with fixes as (

    -- 01040100 Location-Success is the only geo-bearing event. customer_key on
    -- the fix is NOT used for matching (it only says which customer was open in
    -- the app, and 80% of fixes have none) — it is kept solely as a tie-break
    -- signal in step 4.
    select
        e.entity_id,
        e.sales_code,
        coalesce(e.device_name, '?')                                     as device_name,
        e.event_at_utc,
        e.latitude,
        e.longitude,
        e.customer_key                                                   as app_customer_key,
        cast(e.event_at_utc as date)                                     as utc_date,
        coalesce({{ tz_offset_hours('e.device_timezone') }}, 0)          as row_offset_hours
    from {{ ref('int_events_enriched') }} as e
    where e.description_code = '01040100'
      and e.actor_type = 'sales'
      and e.sales_code is not null
      and e.latitude  is not null
      and e.longitude is not null

),

-- ONE timezone offset per rep-day, matching int_rep_customer_activity, so a
-- visit and the app session inside it are read against the same clock.
-- device_timezone is a device setting, not a location: only 43% of rep-days
-- carry a single value.
rep_day_offset as (

    select sales_code, utc_date, row_offset_hours as offset_hours
    from (
        select
            sales_code, utc_date, row_offset_hours,
            row_number() over (
                partition by sales_code, utc_date
                order by count(*) desc, abs(row_offset_hours)
            ) as rn
        from fixes
        group by sales_code, utc_date, row_offset_hours
    ) as ranked
    where rn = 1

),

local_fixes as (

    select
        f.entity_id,
        f.sales_code,
        f.device_name,
        f.event_at_utc,
        f.latitude,
        f.longitude,
        f.app_customer_key,
        {{ add_hours('f.event_at_utc', 'o.offset_hours') }}              as event_at_local
    from fixes as f
    join rep_day_offset as o
        on o.sales_code = f.sales_code
       and o.utc_date   = f.utc_date

),

-- ── step 1 + 2: per-device track, drop physically impossible hops ──────────
sequenced as (

    select
        *,
        lag(latitude) over (
            partition by sales_code, device_name order by event_at_utc, entity_id
        )                                                                as prev_lat,
        lag(longitude) over (
            partition by sales_code, device_name order by event_at_utc, entity_id
        )                                                                as prev_lon,
        lag(event_at_utc) over (
            partition by sales_code, device_name order by event_at_utc, entity_id
        )                                                                as prev_at
    from local_fixes

),

speed_checked as (

    select *
    from (
        select
            *,
            case
                when prev_at is null then 0
                else {{ haversine_metres('prev_lat', 'prev_lon', 'latitude', 'longitude') }}
                     / 1609.34
                     / greatest({{ dbt.datediff('prev_at', 'event_at_utc', 'second') }}, 1)
                     * 3600.0
            end                                                          as implied_mph
        from sequenced
    ) as s
    where implied_mph <= {{ var('presence_max_mph') }}

),

-- ── step 3 + 4: match each fix to the nearest customer inside the geofence ──
stores as (

    select customer_key, latitude as store_lat, longitude as store_lon
    from {{ ref('stg_nav__customer_locations') }}

),

candidates as (

    -- The bounding box is a CHEAP PREFILTER, not the test: it discards pairs
    -- that cannot possibly be within the geofence before any trig runs. Cuts
    -- the join from 27s to 7.8s on 415k fixes x 2.8k stores (measured
    -- 2026-08-13); the haversine below is what actually decides.
    select
        f.entity_id,
        f.sales_code,
        f.device_name,
        f.event_at_utc,
        f.event_at_local,
        f.app_customer_key,
        s.customer_key,
        {{ haversine_metres('f.latitude', 'f.longitude', 's.store_lat', 's.store_lon') }} as metres
    from speed_checked as f
    join stores as s
        on abs(s.store_lat - f.latitude)  < {{ var('presence_geofence_metres') }} / 110000.0
       and abs(s.store_lon - f.longitude) < {{ var('presence_geofence_metres') }} / 85000.0
    where {{ haversine_metres('f.latitude', 'f.longitude', 's.store_lat', 's.store_lon') }}
          <= {{ var('presence_geofence_metres') }}
      -- step 3: the company office is a customer row but not a customer visit
      and {{ haversine_metres('f.latitude', 'f.longitude',
                              var('office_latitude'), var('office_longitude')) }}
          > {{ var('office_radius_metres') }}

),

-- tie-break when several customers share one geofence: prefer the customer the
-- rep actually had open in the app, then the nearest. Same order Annie's
-- process uses. candidate_count is carried so ambiguity stays visible.
ranked_candidates as (

    select
        *,
        count(*) over (partition by entity_id)                           as candidate_count,
        row_number() over (
            partition by entity_id
            order by
                case when customer_key = app_customer_key then 0 else 1 end,
                metres
        )                                                                as pick
    from candidates

),

matched as (

    select
        sales_code, device_name, customer_key, event_at_utc, event_at_local,
        metres, candidate_count
    from ranked_candidates
    where pick = 1

),

-- ── step 5: group consecutive fixes at one store into visits ───────────────
gapped as (

    select
        *,
        case
            when lag(customer_key) over (
                     partition by sales_code, device_name
                     order by event_at_utc
                 ) is distinct from customer_key then 1
            when {{ dbt.datediff(
                    'lag(event_at_utc) over (partition by sales_code, device_name order by event_at_utc)',
                    'event_at_utc', 'minute') }}
                 >= {{ var('presence_visit_gap_minutes') }} then 1
            else 0
        end                                                              as is_new_visit
    from matched

),

numbered as (

    select
        *,
        sum(is_new_visit) over (
            partition by sales_code, device_name
            order by event_at_utc
            rows between unbounded preceding and current row
        )                                                                as raw_visit_seq
    from gapped

),

device_visits as (

    select
        sales_code,
        customer_key,
        device_name,
        cast(min(event_at_local) as date)                                as activity_date,
        min(event_at_local)                                              as arrived_at,
        max(event_at_local)                                              as departed_at,
        count(*)                                                         as fix_count,
        min(metres)                                                      as closest_metres,
        max(candidate_count)                                             as candidate_count
    from numbered
    group by sales_code, customer_key, device_name, raw_visit_seq
    -- step 6: a single ping, or a few seconds in passing, is not a visit
    having {{ dbt.datediff('min(event_at_local)', 'max(event_at_local)', 'minute') }}
           >= {{ var('presence_min_dwell_minutes') }}

),

-- ── step 7: merge the same visit seen by two devices into one ──────────────
merge_flagged as (

    select
        *,
        case
            when lag(customer_key) over (
                     partition by sales_code, customer_key, activity_date order by arrived_at
                 ) is null then 1
            when arrived_at > max(departed_at) over (
                     partition by sales_code, customer_key, activity_date
                     order by arrived_at
                     rows between unbounded preceding and 1 preceding
                 ) then 1
            else 0
        end                                                              as is_new_merged
    from device_visits

),

merge_numbered as (

    select
        *,
        sum(is_new_merged) over (
            partition by sales_code, customer_key, activity_date
            order by arrived_at
            rows between unbounded preceding and current row
        )                                                                as visit_seq
    from merge_flagged

)

select
    sales_code || '-' || customer_key || '-'
        || cast(activity_date as {{ dbt.type_string() }})                as customer_day_key,
    sales_code,
    customer_key,
    activity_date,
    visit_seq,

    min(arrived_at)                                                      as arrived_at,
    max(departed_at)                                                     as departed_at,
    {{ dbt.datediff('min(arrived_at)', 'max(departed_at)', 'minute') }}  as on_site_minutes,

    sum(fix_count)                                                       as fix_count,
    min(closest_metres)                                                  as closest_metres,
    -- true when another customer also sat inside the geofence for any fix in
    -- this visit: the match is plausible but not proven
    max(candidate_count) > 1                                             as is_ambiguous,
    {{ sort_array('array_agg(distinct device_name)') }}                  as devices
from merge_numbered
group by sales_code, customer_key, activity_date, visit_seq
