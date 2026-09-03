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
--  4. MATCH each fix to EVERY customer within var presence_geofence_metres, not
--     just the nearest. Stores share buildings, and nearest-wins was handing the
--     whole visit to one of them -- rep 032 visited PAR017 on 2026-08-26 and it
--     never appeared, because TAI012 (121 m away) was nearer on all twelve
--     fixes. `pick = 1` still marks the old single winner.
--  5. GROUP consecutive fixes into visits, ending on var presence_visit_gap_minutes.
--     NOT first-to-last across the day: min->max lumped two separate stops plus
--     lunch into one 187-minute "visit" during prototyping.
--  6. DROP visits under var presence_min_dwell_minutes. NOW 0 — dwell no longer
--     gates anything. The device reports every 15-30 minutes, so a genuine call
--     often leaves a SINGLE fix inside the geofence and cannot span 3 contiguous
--     minutes; the old threshold was discarding real visits the rep confirmed by
--     name. Proximity decides instead. Trade-off: a drive-past whose one fix
--     happens to land inside now counts too (~4% of what this restores).
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

    -- EVERY geo-bearing event, not just 01040100. The old comment here claimed
    -- "01040100 Location-Success is the only geo-bearing event"; that was wrong
    -- and load-bearing. seed_event_codes flags 24 codes as has_geo, and across
    -- August 2026 the ones this model ignored carried 30,708 positions -- 27% of
    -- all located rows.
    --
    -- They are FRESH, not cached. Measured 2026-09-03 as the distance from each
    -- to the nearest 01040100 fix in time (median):
    --     Login: Username         3,374 rows    0 m
    --     Order List: Sales       1,437 rows    1 m
    --     Create Order            3,757 rows    2 m
    --     Order Detail: Sales       510 rows   11 m
    --     Catalog View            8,386 rows   14 m
    -- The valuable ones are WORK events: a located Create Order says where the
    -- rep stood when he keyed it, which is exactly the corroboration a visit
    -- with no app record otherwise lacks.
    --
    -- THE BLE-ONLY FAMILY IS EXCLUDED. Same measurement: 09050000 median 595 m,
    -- 09080000 281 m, and 09060000 3,675 KM. Those carry a stale or fabricated
    -- position, so they are dropped by code rather than left to the speed filter
    -- -- 595 m inside one reporting interval passes an 80 mph test comfortably.
    select
        e.entity_id,
        e.sales_code,
        coalesce(e.device_name, '?')                                     as device_name,
        e.event_at_utc,
        e.latitude,
        e.longitude,
        e.customer_key                                                   as app_customer_key,
        e.rep_local_date,
        -- shared clock from int_events_enriched. This model and
        -- int_rep_customer_activity MUST read a visit and the session inside it
        -- against the SAME offset. They used to each take their own modal vote
        -- over different event populations — this one over 01040100 pings, which
        -- the PDAs emit constantly, that one over work events, which the iPad
        -- dominates — and disagreed on 33% of rep-days in August 2026. Rep 026's
        -- JUN003 visit on 2026-08-17 read as ending 11:15 on -5 while his app
        -- session ran to 12:09 on -4, so a two-hour on-site stretch reported as
        -- three minutes. The comment here used to CLAIM the two matched.
        e.event_at_local
    from {{ ref('int_events_enriched') }} as e
    where e.expects_geo
      and e.description_code not in ('09050000', '09060000', '09070000', '09080000')
      and e.actor_type = 'sales'
      and e.sales_code is not null
      and e.latitude  is not null
      and e.longitude is not null

),

-- ── app activity per customer, used to bridge a GPS hole ───────────────────
-- Not used for MATCHING -- presence stays derived from GPS alone. Used only to
-- answer one question: while the fixes went quiet, was the rep demonstrably
-- still working THIS customer? If so he did not leave, and the silence is a
-- gap in the evidence rather than a gap in the visit.
customer_activity as (

    select distinct
        sales_code,
        customer_key,
        rep_local_date,
        event_at_utc
    from {{ ref('int_events_enriched') }}
    where actor_type        = 'sales'
      and sales_code       is not null
      and customer_key     is not null
      and description_code <> '01040100'

),

-- one row per rep-day carrying the SHARED clock, joined back at the end rather
-- than threaded through six intermediate CTEs that do not otherwise need it
rep_clock as (

    select distinct
        sales_code,
        rep_local_date                                                   as local_date,
        rep_day_offset_hours
    from {{ ref('int_events_enriched') }}
    where sales_code           is not null
      and rep_day_offset_hours is not null
      and event_at_local       is not null

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
        f.rep_local_date,
        f.event_at_local
    from fixes as f
    where f.event_at_local is not null

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

    -- TEST AND INTERNAL ROWS, by key. The office radius in `candidates` below
    -- catches the ones geocoded to the office, but eleven ZZZ accounts resolve
    -- to "123 Fake St, SAN FRANCISCO" or literally "test", 4.6-25.5 km away,
    -- where the radius never sees them.
    --
    -- INACTIVE ACCOUNTS are now dropped outright. This REVERSES the earlier
    -- decision to keep them as a tie-break -- see the ranked_candidates comment
    -- below, which still describes the old behaviour for the active-vs-active
    -- case. The trade: a rep calling on a lapsed account no longer registers.
    -- What it buys is that duplicate rows for one store stop double-counting --
    -- T&L MARKET is TLM001 (inactive) and TLM002 (active) at the same point,
    -- and both were being credited the same 155 minutes on 2026-08-25.
    select
        customer_key,
        latitude                                                         as store_lat,
        longitude                                                        as store_lon,
        is_active,
        salesperson_code                                                 as owner_rep
    from {{ ref('stg_nav__customer_locations') }}
    where is_active
      and not {{ regex_matches('customer_key', var('test_customer_key_regex')) }}
      and customer_key not in (
          {%- for k in var('test_customer_keys') %}
          '{{ k }}'{{ ',' if not loop.last }}
          {%- endfor %}
      )

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
        f.rep_local_date,
        f.app_customer_key,
        s.customer_key,
        s.is_active,
        s.owner_rep,
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
-- rep actually had open in the app, then an ACTIVE account over a dead one, then
-- the nearest. Same order Annie's process uses, plus the active check.
--
-- Distance alone cannot separate accounts at the SAME address, and 725 geocoded
-- points hold more than one customer. 1085 Reading Rd, Mason OH holds three:
-- HZJ001 and YMA001 (both inactive, rep 901) and YMA002 (active, rep 026). With
-- only app-then-metres, an identical distance fell through to row order and
-- picked the dead account — rep 026 got a 94-minute "visit only, no app" against
-- HZJ001 on 2026-08-17 while the app showed him working YMA002 all along.
--
-- SUPERSEDED, kept because it explains the tie-break order above. Inactive
-- customers USED to reach this point and merely lose every tie. They are now
-- dropped in `stores`, so the is_active branch of the row_number() is dead code
-- and candidate_count counts every candidate rather than only the live ones --
-- is_ambiguous means the same thing either way. The reason for dropping them is
-- in `stores`; the reason for the ordering is here, and the HZJ001/YMA002 case
-- above is still what the app-open-then-nearest order protects against.
ranked_candidates as (

    select
        *,
        sum(case when is_active then 1 else 0 end)
            over (partition by entity_id)                                as candidate_count,
        row_number() over (
            partition by entity_id
            order by
                case when customer_key = app_customer_key then 0 else 1 end,
                case when is_active then 0 else 1 end,
                metres
        )                                                                as pick
    from candidates

),

-- EVERY candidate inside the geofence, not just the nearest. Two customers can
-- share a building, and nearest-wins silently gave the visit to one of them.
-- Measured on rep 032 / 2026-08-26: TAI012, PAR017 and HOA003 sit 121-232 m
-- apart. He parked once for 90 minutes; GPS wobbled +-50 m, so PAR017 fell
-- inside the fence on two fixes (89 m, 90 m) and HOA003 on one (83 m) -- but
-- TAI012 was nearer EVERY time (43/36/81 m), so it took all twelve fixes and
-- PAR017 was never recorded. The rep confirmed he visited PAR017.
--
-- `pick` is kept as a column rather than dropped: pick = 1 still identifies the
-- nearest / app-open / active winner, so a consumer wanting the old one-row
-- behaviour filters on it, and is_ambiguous still means what it meant.
--
-- COST, measured over 6 months with the office already excluded: visit-days go
-- from 8,395 to 20,410 (2.43x) and 1,625 more customers appear. Some of those
-- are real -- a plaza where the rep genuinely called on two accounts -- and some
-- are the neighbour of a place he actually stopped. Distance cannot separate the
-- two when the stores are closer together than GPS error, so this deliberately
-- errs toward recording the possibility rather than silently choosing.
matched as (

    select
        entity_id,
        sales_code, device_name, customer_key, owner_rep, event_at_utc, event_at_local,
        rep_local_date, metres, candidate_count, pick
    from ranked_candidates

),

-- ── step 5: group consecutive fixes at one store into visits ───────────────
-- Partitioned BY CUSTOMER, and NOT by device. One fix can belong to several
-- customers, so a single timeline ordered by time alone interleaves them and the
-- old "customer changed => new visit" test would start a fresh visit on every
-- row. Partitioning by customer_key makes each customer's fixes their own
-- sequence, and the gap test is then the only thing that opens a visit.
--
-- device_name USED to be in this partition, and step 7 below was meant to merge
-- the per-device visits back together. It could not: its test is
-- `arrived_at > previous departed_at`, which merges OVERLAPPING spans, but reps
-- carry 3-5 devices reporting every ~16 min, so they INTERLEAVE rather than
-- overlap. Each device contributed a single fix, each fix became an
-- instantaneous visit, and two instants never overlap -- so one stop fragmented
-- into N zero-minute visits.
--
-- Measured over August 2026 before the fix: 3,825 of 6,266 visits (61%) reported
-- 0 minutes, 1,566 consecutive visits under the 20-minute gap were split purely
-- because the device changed, and total on-site time read 109,355 minutes
-- against 212,649 if merged -- understated by roughly half. LGV001 on 2026-08-25
-- was two 0-minute visits (Honeywell 17:15:04, samsung 17:24:50) instead of one
-- 9-minute call.
--
-- Dropping device_name here does not reintroduce teleporting: speed_checked has
-- already removed impossible hops within each device track, and every fix
-- reaching this point is inside the same 100 m geofence, so ordering across
-- devices is safe.
lagged as (

    select
        *,
        -- rep_local_date IS IN THE PARTITION. Without it the last fix of one day
        -- and the first of the next are 'consecutive', and the bridge below then
        -- spans the night: TAI012 merged into a single 5,843-minute visit and
        -- every downstream customer_day_key it touched broke. A visit cannot
        -- cross a rep-day; that is the grain of this model.
        lag(event_at_utc) over (
            partition by sales_code, customer_key, rep_local_date
            order by event_at_utc
        )                                                                as prev_at
    from matched

),

-- Did the rep keep working THIS customer while the fixes were silent?
--
-- NEW052 on 2026-08-25 is the case. He was in the store from 12:17 to 13:21
-- without a break -- 123 events, longest gap between them 9.5 min -- but one
-- samsung fix at 12:29:24 reported 446 m away while he stood there. That fix
-- falls outside the 100 m fence, so the gap between IN-FENCE fixes became
-- 12:15:18 -> 12:39:10 = 23.9 min, over the 20-minute boundary. One visit split
-- into two, and the 49 events in the hole were labelled 'keyed elsewhere' on a
-- second row spanning a time range that overlapped the first.
--
-- Raising presence_visit_gap_minutes would loosen every visit boundary to fix a
-- GPS-error case. This is narrower: it requires activity FOR THAT CUSTOMER
-- strictly inside the gap, which is positive evidence he never left. Activity
-- for anyone else does not bridge, and neither does silence.
bridged as (

    select
        l.entity_id,
        l.customer_key,
        max(case when a.event_at_utc is not null then 1 else 0 end)       as activity_bridges
    from lagged as l
    left join customer_activity as a
        on  a.sales_code     = l.sales_code
       and  a.customer_key   = l.customer_key
       and  a.rep_local_date = l.rep_local_date
       and  a.event_at_utc   > l.prev_at
       and  a.event_at_utc   < l.event_at_utc
    group by l.entity_id, l.customer_key

),

gapped as (

    select
        l.*,
        b.activity_bridges,
        case
            when l.prev_at is null then 1
            when {{ dbt.datediff('l.prev_at', 'l.event_at_utc', 'minute') }}
                 >= {{ var('presence_visit_gap_minutes') }}
             and b.activity_bridges = 0 then 1
            else 0
        end                                                              as is_new_visit
    from lagged as l
    join bridged as b
        on  b.entity_id    = l.entity_id
       and  b.customer_key = l.customer_key

),

numbered as (

    select
        *,
        sum(is_new_visit) over (
            partition by sales_code, customer_key, rep_local_date
            order by event_at_utc
            rows between unbounded preceding and current row
        )                                                                as raw_visit_seq
    from gapped

),

device_visits as (

    select
        sales_code,
        customer_key,
        {{ sort_array('array_agg(distinct device_name)') }}               as device_names,
        min(rep_local_date)                                             as activity_date,
        min(event_at_local)                                              as arrived_at,
        max(event_at_local)                                              as departed_at,
        count(*)                                                         as fix_count,
        min(metres)                                                      as closest_metres,
        max(candidate_count)                                             as candidate_count,
        max(owner_rep)                                                   as owner_rep,
        -- the GPS fixes this visit is built from. Published so a consumer can
        -- ask whether two visits are the SAME MOMENT rather than merely
        -- overlapping: one fix can match several customers, so two visits
        -- sharing an identical fix set are one position seen through two
        -- geofences, not two calls.
        array_agg(entity_id)                                             as fix_ids
    from numbered
    -- rep_local_date is in the key because raw_visit_seq restarts each day
    -- (its running sum is partitioned by day); without it, day 1's visit 1
    -- and day 2's visit 1 collapse into one group.
    group by sales_code, customer_key, rep_local_date, raw_visit_seq
    -- step 6: dwell gate. presence_min_dwell_minutes is 0, so this passes
    -- everything -- see the var's comment in dbt_project.yml for why. Kept as a
    -- filter rather than deleted so the threshold can be raised again in one
    -- place if the device ever reports at a useful cadence.
    having {{ dbt.datediff('min(event_at_local)', 'max(event_at_local)', 'minute') }}
           >= {{ var('presence_min_dwell_minutes') }}

),

-- ── step 7: number the visits ───────────────────────────────────
-- This used to be the cross-device merge. Step 5 now does that work by not
-- splitting on device in the first place, so what remains here is sequence
-- numbering plus a safety net for any residual overlap.
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
    v.sales_code || '-' || v.customer_key || '-'
        || cast(v.activity_date as {{ dbt.type_string() }})                as customer_day_key,
    v.sales_code,
    v.customer_key,
    v.activity_date,
    v.visit_seq,

    min(v.arrived_at)                                                      as arrived_at,
    max(v.departed_at)                                                     as departed_at,
    {{ dbt.datediff('min(v.arrived_at)', 'max(v.departed_at)', 'minute') }}  as on_site_minutes,

    sum(fix_count)                                                       as fix_count,
    min(closest_metres)                                                  as closest_metres,
    -- true when another customer also sat inside the geofence for any fix in
    -- this visit: the match is plausible but not proven
    max(v.candidate_count) > 1                                           as is_ambiguous,
    {{ sort_array(array_distinct('flatten(array_agg(v.device_names))')) }}  as devices,
    max(v.owner_rep)                                                     as owner_rep,
    max(v.owner_rep) = v.sales_code                                      as is_owned_by_rep,
    {{ sort_array(array_distinct('flatten(array_agg(v.fix_ids))')) }}       as fix_ids,
    -- published so the shared-clock invariant is TESTABLE rather than merely
    -- asserted in a comment, which is how an hour-wide disagreement with
    -- int_rep_customer_activity went unnoticed. See
    -- tests/assert_presence_and_activity_share_one_clock.sql
    max(c.rep_day_offset_hours)                                          as rep_day_offset_hours
from merge_numbered as v
left join rep_clock as c
    on c.sales_code = v.sales_code
   and c.local_date = v.activity_date
group by v.sales_code, v.customer_key, v.activity_date, v.visit_seq
