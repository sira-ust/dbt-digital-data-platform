-- mart_rep_customer_activity — one row per REP x CUSTOMER x DAY x SCENARIO.
--
--   Customer | Scenario | Sessions | PDA (mins) | iPad (mins) | On-site (mins)
--            | Opened at | Orders | Events
--
-- SCENARIO is the point of this model. A rep can work the same customer both
-- on-site and remotely on one day, and a single per-day label hides that: on
-- 2026-08-10 rep 025 built three baskets in-store (71/47/79 events) and
-- submitted all three at 22:42 that evening. Collapsed, that read "on-site,
-- order M000182028" and implied he sent it there. He did not. Split by
-- scenario it reads honestly — three on-site rows carrying the minutes, three
-- "visited, keyed elsewhere" rows carrying the orders.
--
--   remote                    never on-site, rep did the work
--   on-site                   session overlaps a GPS-confirmed visit
--   visited, keyed elsewhere  visited that day, but this session was not there
--   customer ordered online   arrived already placed (order_channel WEB/APP)
--   visit only, no app        on-site with NO app activity at all
--   text/email order INFERRED, not measured -- a strict subset of
--                             `remote` where he keyed it in one sitting, fast,
--                             browsed almost nothing and typed every line
--                             instead of tapping it off history: the customer
--                             sent the order and he transcribed it. Cannot name
--                             the channel -- a phone call looks identical. See
--                             the case expression for thresholds.
--
-- The last one is why this is a FULL OUTER JOIN of activity and presence: a
-- visit that produced no typing has no activity row, so an inner join would
-- erase exactly the case the business most wants counted.
--
-- WHAT IS EXACT: the customer, the device split, the order numbers, and the
-- GPS distance. WHAT IS INFERRED: session boundaries (idle gaps, since cart
-- events carry no order number) and which customer a fix belongs to when two
-- sit inside one geofence — see is_ambiguous.
--
-- WHEN THERE IS NO GPS the scenario cannot be determined, and the row is
-- labelled `unknown` rather than `remote`. 12% of customers have no
-- coordinates and 18% of rep-days have no fixes; calling those "remote" would
-- report absence of evidence as evidence of absence.
--
-- Device minutes are measured in STINTS (unbroken runs on one device) in
-- SECONDS, rounded once per device, so a PDA -> iPad -> PDA handoff is never
-- billed to either device and short bursts are not inflated.
--
-- Full-rebuild table: session and visit boundaries shift as events land.

with activity_events as (

    select * from {{ ref('int_rep_customer_activity') }}

),

presence as (

    select * from {{ ref('int_rep_customer_presence') }}

),

-- ── was each EVENT inside a visit, or outside it? ─────────────────────────
-- Flagged per event, NOT per session, because the two are different shapes. A
-- session ends only on an idle gap of var('activity_gap_minutes'), so it happily
-- runs straight through the rep walking out of the store — into the car, or the
-- evening at home. Testing "did the session overlap the visit at all" then
-- labels the WHOLE session on-site on the strength of any overlap.
--
-- Measured on rep 026 / 2026-08-17: his JUN003 session touched the visit for
-- THREE MINUTES (10 events, 11:12-11:15) and then ran another 53 minutes and 829
-- events after he left, all of it reported as on-site. NEW051 and YMA002 were
-- genuine mixed sessions — 476 events in store then 346 after, and 178 then 285.
--
-- Splitting here means one session can produce TWO rows, one per side of the
-- boundary. That is the same grain change the scenario column already made at
-- day level, and for the same reason: a single label cannot describe both halves
-- without lying about one of them.
event_placement as (

    select
        e.entity_id,
        e.customer_day_key,
        e.sales_code,
        e.customer_key,
        e.activity_date,
        e.session_seq,
        e.event_at_local,
        e.customer_key_source,
        -- carried for the 'texted/emailed order' test in `labelled` below
        e.is_add,
        e.feature_name,
        e.description_code,
        e.seconds_since_prev_event,
        -- The window edges are GPS SAMPLE times, not arrival and departure, so
        -- they are padded by var('presence_edge_tolerance_minutes'). See that
        -- var for why the test stays PER EVENT rather than moving to per
        -- session, and what breaks if it does.
        max(case
                when {{ dbt.dateadd('minute',
                        '-' ~ var('presence_edge_tolerance_minutes'), 'v.arrived_at') }}
                        <= e.event_at_local
                 and e.event_at_local <=
                     {{ dbt.dateadd('minute',
                        var('presence_edge_tolerance_minutes'), 'v.departed_at') }} then 1
                else 0
            end)                                                         as was_on_site
    from activity_events as e
    left join presence as v
        on v.customer_day_key = e.customer_day_key
    group by
        e.entity_id, e.customer_day_key, e.sales_code, e.customer_key,
        e.activity_date, e.session_seq, e.event_at_local, e.customer_key_source,
        e.is_add, e.feature_name, e.description_code, e.seconds_since_prev_event

),

-- ── number the CONTIGUOUS RUNS of on-site / off-site within a session ───────
-- session_bounds below groups by (session_seq, was_on_site), so two SEPARATE
-- on-site stretches in one session collapse into a single portion and its
-- first_touch..last_touch span silently covers the off-site stretch between
-- them. NEW052 on 2026-08-25 reads 12:17-13:17 on-site and 12:18-13:21
-- elsewhere -- overlapping ranges that look like a bug but are really four
-- alternating runs (on 12:17-12:17, off 12:18-12:29, on 12:39-13:17, off
-- 13:18-13:21) flattened to two min/max pairs.
--
-- The gap is genuine: 39 events fall in a 24-minute silence between fixes, so
-- the model cannot place him and 'elsewhere' is the honest label. What was
-- missing is any signal that the span is NOT contiguous, which is what
-- segment_seq counts.
segmented as (

    select
        e.*,
        sum(case when e.was_on_site = lag(e.was_on_site) over (
                      partition by e.customer_day_key, e.session_seq
                      order by e.event_at_local, e.entity_id)
                 then 0 else 1 end) over (
            partition by e.customer_day_key, e.session_seq
            order by e.event_at_local, e.entity_id
            rows between unbounded preceding and current row
        )                                                                as segment_seq
    from event_placement as e

),

-- ── classify every SESSION PORTION against the visits for that customer-day ─
session_bounds as (

    select
        e.customer_day_key,
        e.sales_code,
        e.customer_key,
        e.activity_date,
        e.session_seq,
        e.was_on_site,
        min(e.event_at_local)                                            as session_start,
        max(e.event_at_local)                                            as session_end,
        count(*)                                                         as event_count,
        sum(case when e.customer_key_source <> 'event' then 1 else 0 end) as inherited_event_count,
        -- behavioural shape of this session portion, for the scenario test below
        sum(case when e.is_add then 1 else 0 end)                        as item_count,
        sum(case when e.feature_name is not null then 1 else 0 end)      as browse_count,
        sum(case when e.description_code = '10050900' then 1 else 0 end) as typed_count,
        {{ median('case when e.is_add then e.seconds_since_prev_event end') }} as median_sec_per_item,
        count(distinct e.segment_seq)                                    as segments
    from segmented as e
    group by
        e.customer_day_key, e.sales_code, e.customer_key, e.activity_date,
        e.session_seq, e.was_on_site

),

-- every order a session actually submitted, not just one. A session can
-- submit more than one order (e.g. two back-to-back sends) — collapsing to a
-- single MAX(increment_id) silently dropped every order but the
-- lexicographically largest one (confirmed on real data 2026-08-20: 4 of 42
-- order-bearing sessions for one rep alone had 2 distinct orders, and the
-- mart was missing all 4 of the lower-sorting ones). `distinct` here is the
-- resubmit case (same increment_id logged twice), a different thing from
-- multiple genuinely different orders — both are handled by carrying every
-- DISTINCT increment_id through as an array instead of picking one.
-- order_channel (PDA = rep keyed it, WEB/APP = customer placed it) lives on
-- fct_orders, not the intermediate; verified consistent across every
-- multi-order session found, so one value per session is still safe.
session_orders as (

    select
        customer_day_key,
        session_seq,
        array_agg(increment_id)                                          as increment_ids,
        max(order_channel)                                               as order_channel
    from (
        select distinct
            e.customer_day_key, e.session_seq, e.increment_id, o.order_channel
        from activity_events as e
        left join {{ ref('fct_orders') }} as o
            on o.increment_id = e.increment_id
        where e.is_submit
    ) as submits
    group by customer_day_key, session_seq

),

session_scenario as (

    select
        b.*,
        so.increment_ids,
        so.order_channel,
        -- was THIS PORTION of the session inside a visit? Decided per event in
        -- event_placement, so a session straddling the departure contributes one
        -- on-site row and one 'keyed elsewhere' row instead of being labelled
        -- wholly on-site on the strength of a 3-minute overlap.
        b.was_on_site                                                     as during_visit,
        max(case when v.customer_day_key is not null then 1 else 0 end)   as visited_that_day,
        max(case when v.is_ambiguous then 1 else 0 end)                   as is_ambiguous,
        -- Attributed ONLY to the on-site portion. Splitting a session at the
        -- visit boundary means both halves still overlap the visit window in
        -- wall-clock terms, so the old overlap test handed the same visit's
        -- minutes to BOTH rows: rep 026 on 2026-08-18 summed to 449 on-site
        -- minutes against a true GPS total of 307, because SUN013 (66) and
        -- SUN015 (76) were each counted twice. was_on_site already identifies
        -- which portion was actually inside the visit, so the minutes go there
        -- and the keyed-elsewhere row gets zero.
        -- PADDED on both edges, the same way event_placement classifies. They
        -- must agree: event_placement used the padded window to call NEW057
        -- 'on-site' on 2026-08-25 while this test used the raw window, found no
        -- overlap (its session ended 16:18:59, its first fix was 16:20:01) and
        -- awarded 0 minutes -- an on-site visit reporting no on-site time.
        sum(case when b.was_on_site = 1
                  and {{ dbt.dateadd('minute',
                          '-' ~ var('presence_edge_tolerance_minutes'), 'v.arrived_at') }}
                          <= b.session_end
                  and b.session_start <=
                      {{ dbt.dateadd('minute',
                          var('presence_edge_tolerance_minutes'), 'v.departed_at') }}
                 then v.on_site_minutes else 0 end)                       as overlap_on_site_minutes
    from session_bounds as b
    left join session_orders as so
        on so.customer_day_key = b.customer_day_key
       and so.session_seq      = b.session_seq
    left join presence as v
        on v.customer_day_key = b.customer_day_key
    group by
        b.customer_day_key, b.sales_code, b.customer_key, b.activity_date,
        b.session_seq, b.was_on_site, b.session_start, b.session_end,
        b.event_count, b.inherited_event_count, b.segments,
        b.item_count, b.browse_count, b.typed_count, b.median_sec_per_item,
        so.increment_ids, so.order_channel

),

-- how many separate sittings did this customer-day hold? `one shot` in the
-- scenario test below means exactly one -- he opened it, keyed it, sent it, and
-- never came back. Counted per DAY because each session_bounds row is a single
-- stretch by construction, so a session-level test would always be true.
day_sessions as (

    select customer_day_key, count(distinct session_seq) as sessions_that_day
    from activity_events
    group by customer_day_key

),

-- ── can this rep-day be classified at all? ────────────────────────────────
-- `unknown` exists for two honest reasons, both about MISSING EVIDENCE: the rep
-- logged no usable GPS that day, or the customer has no coordinates so no
-- geofence can be drawn. It must never mean "he had GPS and was elsewhere" --
-- that is `remote`.
--
-- This used to read `select distinct sales_code, activity_date from presence`,
-- and presence holds MATCHED VISITS, not fixes. So a rep-day only counted as
-- "has GPS" if he actually stopped at somebody. A rep who worked from home all
-- day with his PDA pinging 84 times was labelled "we do not know where he was",
-- when we knew precisely: not at any customer.
--
-- Measured 2026-08-27: of 6,599 `unknown` rows, 6,596 had usable GPS AND a
-- geocoded customer -- 100% mislabelled, since the remaining 3 were the genuine
-- ungeocoded case. Rep 032 had 79 such order-days, every one with GPS present
-- (84 fixes a day on average).
gps_days as (

    select distinct
        sales_code,
        rep_local_date                                                   as activity_date
    from {{ ref('int_events_enriched') }}
    where description_code = '01040100'
      and actor_type       = 'sales'
      and sales_code       is not null
      and latitude         is not null
      and longitude        is not null

),

-- a customer with no coordinate cannot be geofenced, so his absence from a
-- visit list is not evidence. Excluded rows are a left-join miss, which is the
-- honest shape -- see stg_nav__customer_locations.
geocoded_customers as (

    select customer_key
    from {{ ref('stg_nav__customer_locations') }}
    where latitude is not null and longitude is not null

),

labelled as (

    select
        s.*,
        case
            when s.order_channel in ('WEB', 'APP')       then 'customer ordered online'
            when s.during_visit = 1                      then 'on-site'
            when s.visited_that_day = 1                  then 'visited, keyed elsewhere'
            -- no usable GPS that rep-day, OR this customer cannot be geofenced
            when g.sales_code is null
              or gc.customer_key is null                  then 'unknown'
            -- ── the customer sent the order in; he only typed it ──────────
            -- INFERRED, unlike every label above it. The rest of this column is
            -- evidence -- a GPS fix, or the channel off the order payload. This
            -- one is a behavioural read, so it sits LAST and can only ever split
            -- `remote`: add the two together to recover the original figure.
            --
            -- It can only ever split `remote`; add the two together to recover
            -- the original figure. It sits LAST for that reason, and the
            -- position also enforces the first two conditions for free.
            --
            -- It does NOT overlap `visited, keyed elsewhere`, and must not: the
            -- defining condition is that no GPS fix placed him at that store
            -- THAT DAY, which is exactly the negation of having visited. By the
            -- time execution reaches here `visited_that_day = 0` is already
            -- true, so on_site_min = 0 at day level needs no restating. A day he
            -- visited belongs to `on-site` or `visited, keyed elsewhere` however
            -- the keying looked.
            --
            -- `unknown` has likewise already taken the no-GPS days, so GPS
            -- demonstrably exists and demonstrably puts him elsewhere. Ordering
            -- the branch below `unknown` is what keeps absence of evidence from
            -- being read as evidence of absence.
            --
            -- The remaining three are behavioural, and this is the shape: he
            -- keyed a substantial order in ONE unbroken sitting, fast, looked
            -- almost nothing up, and typed every line rather than tapping it off
            -- purchase history. He was reading from something we cannot see.
            -- Calibrated on rep 028 over 6 months: remote days average 0.24
            -- browse per item and 94% typed, against 0.57 and 64% on-site.
            --
            -- IT DOES NOT NAME THE CHANNEL. A phone call, or a list handed over
            -- on an earlier visit, leaves the same trace. It says the order
            -- reached him from outside the app, not that it arrived by text.
            --
            -- browse_count is the weakest of the three and partly a device
            -- proxy: the PDA has no catalog_view or filter instrumentation, so
            -- it browses ~0.13 per add against the iPad's 0.46. typed_count is
            -- the strongest -- it is a choice made WITHIN one device.
            --
            -- DEPENDS ON THE DEDUPE in int_events_decoded. With the duplicate
            -- batch rows present, two of every three add-gaps are 0,
            -- median_sec_per_item collapses to 0, and the <= 10 test fires on
            -- everything.
            when d.sessions_that_day = 1
             and s.item_count          >= 10
             and s.median_sec_per_item <= 10
             and s.browse_count * 1.0 / s.item_count <  0.25
             and s.typed_count  * 1.0 / s.item_count >= 0.90
                                                         then 'text/email order'
            else 'remote'
        end                                                              as scenario
    from session_scenario as s
    left join gps_days as g
        on g.sales_code = s.sales_code and g.activity_date = s.activity_date
    left join geocoded_customers as gc
        on gc.customer_key = s.customer_key
    left join day_sessions as d
        on d.customer_day_key = s.customer_day_key

),

-- ── device minutes per session, from stints ───────────────────────────────
-- Keyed on device_group, NOT device: while BLE-paired the rep drives the iPad
-- from the PDA, so events alternate every few seconds. Splitting a stint on
-- every flip bills the time between them to neither device, which is why rep
-- 026 / JUN003 / 2026-08-17 reported pda_minutes = 0 on a session holding 5 PDA
-- events. A pairing is therefore ONE stint carrying paired_seconds.
stints as (

    select
        customer_day_key,
        session_seq,
        was_on_site,
        device_group,
        {{ dbt.datediff('min(event_at_utc)', 'max(event_at_utc)', 'second') }} as stint_seconds
    from (
        select
            e.customer_day_key, e.session_seq, p.was_on_site, e.device_group,
            e.event_at_utc, e.entity_id,
            -- Islands over the WHOLE session, so a stint breaks whenever either
            -- the device OR the in/out-of-visit state changes. Partitioning the
            -- outer row_number by was_on_site instead made the off-visit events
            -- look consecutive across the on-site stretch sitting between them,
            -- so their stint span was measured end to end: SUN015 on 2026-08-18
            -- billed 105 minutes to "visited, keyed elsewhere" for two fragments
            -- (14:12-14:14 and 15:30-15:57) either side of a 76-minute visit.
            row_number() over (partition by e.customer_day_key, e.session_seq
                               order by e.event_at_utc, e.entity_id)
          - row_number() over (partition by e.customer_day_key, e.session_seq,
                                            e.device_group, p.was_on_site
                               order by e.event_at_utc, e.entity_id)      as stint_grp
        from activity_events as e
        join event_placement as p
            on p.entity_id = e.entity_id
    ) as runs
    group by customer_day_key, session_seq, was_on_site, device_group, stint_grp

),

session_device as (

    select
        customer_day_key,
        session_seq,
        was_on_site,
        sum(case when device_group = 'PDA'            then stint_seconds else 0 end) as pda_seconds,
        sum(case when device_group = 'iPad'           then stint_seconds else 0 end) as ipad_seconds,
        sum(case when device_group = 'Android tablet' then stint_seconds else 0 end) as tablet_seconds,
        sum(case when device_group = 'PDA + iPad (paired)'
                                                      then stint_seconds else 0 end) as paired_seconds
    from stints
    group by customer_day_key, session_seq, was_on_site

),

-- ── roll sessions up to customer x day x scenario ──────────────────────────
by_scenario as (

    select
        l.customer_day_key,
        l.sales_code,
        l.customer_key,
        l.activity_date,
        l.scenario,
        count(*)                                                         as sessions,
        -- >1 means the time range below is NOT one continuous stretch
        sum(l.segments)                                                  as segments,
        -- rounded per DEVICE, not per stint, so the columns sum to keying_minutes
        cast(round(sum(d.pda_seconds)    / 60.0) as {{ dbt.type_int() }}) as pda_minutes,
        cast(round(sum(d.ipad_seconds)   / 60.0) as {{ dbt.type_int() }}) as ipad_minutes,
        cast(round(sum(d.tablet_seconds) / 60.0) as {{ dbt.type_int() }}) as android_tablet_minutes,
        cast(round(sum(d.paired_seconds) / 60.0) as {{ dbt.type_int() }}) as paired_minutes,
        max(l.overlap_on_site_minutes)                                   as on_site_minutes,
        {{ sort_array('array_agg(' ~ format_hhmm('l.session_start') ~ ')') }}   as opened_at,
        min(l.session_start)                                             as first_touch_local,
        max(l.session_end)                                               as last_touch_local,
        sum(l.event_count)                                               as event_count,
        sum(l.inherited_event_count)                                     as inherited_event_count,
        max(l.is_ambiguous) = 1                                          as is_ambiguous
    from labelled as l
    left join session_device as d
        on d.customer_day_key = l.customer_day_key
       and d.session_seq      = l.session_seq
       and d.was_on_site      = l.was_on_site
    group by l.customer_day_key, l.sales_code, l.customer_key, l.activity_date, l.scenario

),

-- orders per scenario, deduped (a resubmit logs the same increment_id twice).
-- increment_ids is one array per SESSION, so explode it to one row per order
-- before deduping — a session that submitted 2 distinct orders must produce 2
-- rows here, not collapse to 1.
scenario_orders as (

    select
        customer_day_key, scenario,
        count(*)                                                         as orders_submitted,
        sum(case when order_channel = 'PDA'          then 1 else 0 end)  as orders_keyed,
        sum(case when order_channel in ('WEB','APP') then 1 else 0 end)  as orders_received,
        array_agg(increment_id)                                          as order_ids
    from (
        select distinct customer_day_key, scenario, increment_id, order_channel
        from (
            select
                customer_day_key, scenario, order_channel,
                {{ unnest('increment_ids') }}                            as increment_id
            from labelled
            where increment_ids is not null
        ) as exploded
        where increment_id is not null
    ) as deduped
    group by customer_day_key, scenario

),

-- ── the FULL OUTER half: visits with no app activity at all ───────────────
-- ── visits with NO app record for the customer ─────────────────────────────
-- These rest on GPS position alone, so three tests apply that a visit backed by
-- a device record does not need. Each was measured against a rep's own account
-- of his day, not chosen for tidiness.
--
--  1. DISTANCE. var('presence_no_activity_max_metres'), 80 m. The record is the
--     proof where one exists; where none does, the position must be better.
--  2. OWNERSHIP. Standing near a store that belongs to ANOTHER rep is not
--     evidence of calling on it. On 2026-08-25 one GPS fix at 17:32 put rep 030
--     25 m from ASI006 (rep 025) and 71 m from PEE001 (rep 030); crediting the
--     nearer one on distance alone was wrong. Activity-backed visits are exempt
--     -- a rep may legitimately transact on a colleague's account.
--  3. SAME MOMENT. A no-activity visit whose fix set is IDENTICAL to an
--     activity-backed one is that visit seen through a neighbour's fence: same
--     arrival, same departure, same every fix between. YIN001 shared all nine of
--     NEW052's fixes while NEW052 carried 98 device records and an order.
--     EQUALITY ONLY, never containment: PAR017's 3 fixes are a subset of
--     TAI012's 17 and rep 032 confirmed PAR017 by name -- a shorter call inside
--     a longer stop is exactly what a real second visit looks like.
--  4. ARRIVAL LEG. Zero dwell on every touch, and shares a fix with an
--     activity-backed visit => it is that visit's approach, not a stop. SEV009's
--     13:31:10 fix IS NEW007's first fix. Requires 0 min on ALL touches, so
--     GAN003 (31 min) and PAR017 (20 min) are untouched -- both confirmed real.
--
-- A rule dropping a row whose window activity belonged to another customer was
-- tried and REJECTED: it deleted GAN003 and PAR017. Rep 032 keyed TAI012's order
-- from Gangnam's kerb, and doing other paperwork while on site says nothing
-- about whether this visit happened.
with_activity as (

    select
        v.sales_code,
        v.activity_date,
        v.customer_key,
        {{ sort_array(array_distinct('flatten(array_agg(v.fix_ids))')) }}   as fix_ids
    from presence as v
    -- EXISTS, not a join: a customer with two scenario rows (NEW052 is both
    -- 'on-site' and 'visited, keyed elsewhere') would otherwise be joined twice
    -- and its fix array doubled, so fix-set equality below silently never fired.
    where exists (
        select 1 from by_scenario as a
        where a.customer_day_key = v.customer_day_key
    )
    group by v.sales_code, v.activity_date, v.customer_key

),

visit_only_candidates as (

    select
        v.customer_day_key,
        v.sales_code,
        v.customer_key,
        v.activity_date,
        sum(v.on_site_minutes)                                           as on_site_minutes,
        max(v.on_site_minutes)                                           as longest_touch_minutes,
        max(v.is_ambiguous)                                              as is_ambiguous,
        min(v.closest_metres)                                            as closest_metres,
        max(case when v.is_owned_by_rep then 1 else 0 end)               as is_owned_by_rep,
        {{ sort_array(array_distinct('flatten(array_agg(v.fix_ids))')) }}   as fix_ids
    from presence as v
    left join by_scenario as a
        on a.customer_day_key = v.customer_day_key
    where a.customer_day_key is null
    group by v.customer_day_key, v.sales_code, v.customer_key, v.activity_date

),

visit_only as (

    select
        c.customer_day_key,
        c.sales_code,
        c.customer_key,
        c.activity_date,
        c.on_site_minutes,
        c.is_ambiguous
    from visit_only_candidates as c
    where c.closest_metres <= {{ var('presence_no_activity_max_metres') }}   -- 1
      and c.is_owned_by_rep = 1                                              -- 2
      and not exists (                                                       -- 3
          select 1 from with_activity as w
          where w.sales_code    = c.sales_code
            and w.activity_date = c.activity_date
            and w.fix_ids       = c.fix_ids
      )
      and not (                                                              -- 4
          c.longest_touch_minutes = 0
          and exists (
              select 1 from with_activity as w
              where w.sales_code    = c.sales_code
                and w.activity_date = c.activity_date
                and {{ arrays_overlap('w.fix_ids', 'c.fix_ids') }}
          )
      )

),

-- one display name per territory code (guard against join fan-out)
reps as (

    select salesperson_code, max(first_name || ' ' || last_name)         as rep_name
    from {{ ref('stg_mysql__admin_users') }}
    where salesperson_code is not null
    group by salesperson_code

),

combined as (

    select
        a.customer_day_key, a.sales_code, a.customer_key, a.activity_date,
        a.scenario, a.sessions, a.segments,
        a.pda_minutes, a.ipad_minutes, a.android_tablet_minutes, a.paired_minutes,
        a.inherited_event_count,
        a.on_site_minutes, a.opened_at,
        a.first_touch_local, a.last_touch_local,
        coalesce(o.orders_submitted, 0)                                  as orders_submitted,
        coalesce(o.orders_keyed, 0)                                      as orders_keyed,
        coalesce(o.orders_received, 0)                                   as orders_received,
        o.order_ids,
        a.event_count,
        a.is_ambiguous
    from by_scenario as a
    left join scenario_orders as o
        on o.customer_day_key = a.customer_day_key and o.scenario = a.scenario

    union all

    select
        v.customer_day_key, v.sales_code, v.customer_key, v.activity_date,
        'visit only, no app'                                             as scenario,
        0                                                                as sessions,
        -- no app session at all, so nothing to be discontiguous
        1                                                                as segments,
        0, 0, 0, 0,
        0                                                                as inherited_event_count,
        v.on_site_minutes,
        {{ null_string_array() }}                                        as opened_at,
        cast(null as timestamp), cast(null as timestamp),
        0, 0, 0,
        {{ null_string_array() }}                                        as order_ids,
        0                                                                as event_count,
        v.is_ambiguous
    from visit_only as v

)

select
    c.customer_day_key,
    c.sales_code,
    r.rep_name,
    c.customer_key,
    c.activity_date,
    c.scenario,
    c.sessions,
    c.segments,

    c.pda_minutes,
    c.ipad_minutes,
    c.android_tablet_minutes,
    -- time worked with the iPad BLE-paired to the PDA. Kept separate because it
    -- cannot be split between the two: they are one workstation for that stretch.
    c.paired_minutes,
    c.pda_minutes + c.ipad_minutes + c.android_tablet_minutes
        + c.paired_minutes                                               as keying_minutes,
    c.on_site_minutes,

    c.opened_at,
    c.first_touch_local,
    c.last_touch_local,

    c.orders_submitted,
    c.orders_keyed,
    c.orders_received,
    c.order_ids,

    c.event_count,
    -- how many of those events only have a customer because a BLE pairing let us
    -- inherit it. Compare against event_count before treating a row as exact.
    c.inherited_event_count,
    c.is_ambiguous,

    -- the standard noise filter: the rep spent measurable time, sent/handled an
    -- order, or was physically there. False only when none of those hold.
    -- Do NOT filter on event_count instead — `event_count >= 4` discards 31% of
    -- all orders, because a submit landing with no preceding cart activity is a
    -- legitimate one-event row.
    (c.pda_minutes + c.ipad_minutes + c.android_tablet_minutes
        + c.paired_minutes > 0
     or c.orders_submitted > 0
     or coalesce(c.on_site_minutes, 0) > 0)                              as has_activity
from combined as c
left join reps as r
    on r.salesperson_code = c.sales_code
