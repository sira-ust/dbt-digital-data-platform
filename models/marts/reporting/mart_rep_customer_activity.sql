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

-- ── classify every SESSION against the visits for that customer-day ────────
-- order_channel (PDA = rep keyed it, WEB/APP = customer placed it) lives on
-- fct_orders, not the intermediate. fct_orders is unique on increment_id so
-- this cannot fan out.
session_bounds as (

    select
        e.customer_day_key,
        e.sales_code,
        e.customer_key,
        e.activity_date,
        e.session_seq,
        min(e.event_at_local)                                            as session_start,
        max(e.event_at_local)                                            as session_end,
        count(*)                                                         as event_count,
        max(case when e.is_submit then e.increment_id end)               as increment_id,
        max(case when e.is_submit then o.order_channel end)              as order_channel
    from activity_events as e
    left join {{ ref('fct_orders') }} as o
        on o.increment_id = e.increment_id
    group by e.customer_day_key, e.sales_code, e.customer_key, e.activity_date, e.session_seq

),

session_scenario as (

    select
        b.*,
        -- did THIS session happen inside a visit to THIS customer?
        max(case when v.arrived_at <= b.session_end
                  and b.session_start <= v.departed_at then 1 else 0 end) as during_visit,
        max(case when v.customer_day_key is not null then 1 else 0 end)   as visited_that_day,
        max(case when v.is_ambiguous then 1 else 0 end)                   as is_ambiguous,
        sum(case when v.arrived_at <= b.session_end
                  and b.session_start <= v.departed_at
                 then v.on_site_minutes else 0 end)                       as overlap_on_site_minutes
    from session_bounds as b
    left join presence as v
        on v.customer_day_key = b.customer_day_key
    group by
        b.customer_day_key, b.sales_code, b.customer_key, b.activity_date,
        b.session_seq, b.session_start, b.session_end, b.event_count,
        b.increment_id, b.order_channel

),

-- a rep-day with no GPS at all cannot be classified: `unknown`, not `remote`
gps_days as (

    select distinct sales_code, activity_date
    from presence

),

labelled as (

    select
        s.*,
        case
            when s.order_channel in ('WEB', 'APP')       then 'customer ordered online'
            when s.during_visit = 1                      then 'on-site'
            when s.visited_that_day = 1                  then 'visited, keyed elsewhere'
            when g.sales_code is null                    then 'unknown'
            else 'remote'
        end                                                              as scenario
    from session_scenario as s
    left join gps_days as g
        on g.sales_code = s.sales_code and g.activity_date = s.activity_date

),

-- ── device minutes per session, from stints ───────────────────────────────
stints as (

    select
        customer_day_key,
        session_seq,
        device,
        {{ dbt.datediff('min(event_at_utc)', 'max(event_at_utc)', 'second') }} as stint_seconds
    from (
        select
            customer_day_key, session_seq, device, event_at_utc,
            row_number() over (partition by customer_day_key, session_seq
                               order by event_at_utc, entity_id)
          - row_number() over (partition by customer_day_key, session_seq, device
                               order by event_at_utc, entity_id)          as stint_grp
        from activity_events
    ) as runs
    group by customer_day_key, session_seq, device, stint_grp

),

session_device as (

    select
        customer_day_key,
        session_seq,
        sum(case when device = 'PDA'            then stint_seconds else 0 end) as pda_seconds,
        sum(case when device = 'iPad'           then stint_seconds else 0 end) as ipad_seconds,
        sum(case when device = 'Android tablet' then stint_seconds else 0 end) as tablet_seconds
    from stints
    group by customer_day_key, session_seq

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
        -- rounded per DEVICE, not per stint, so the columns sum to keying_minutes
        cast(round(sum(d.pda_seconds)    / 60.0) as {{ dbt.type_int() }}) as pda_minutes,
        cast(round(sum(d.ipad_seconds)   / 60.0) as {{ dbt.type_int() }}) as ipad_minutes,
        cast(round(sum(d.tablet_seconds) / 60.0) as {{ dbt.type_int() }}) as android_tablet_minutes,
        max(l.overlap_on_site_minutes)                                   as on_site_minutes,
        {{ sort_array('array_agg(' ~ format_hhmm('l.session_start') ~ ')') }}   as opened_at,
        min(l.session_start)                                             as first_touch_local,
        max(l.session_end)                                               as last_touch_local,
        sum(l.event_count)                                               as event_count,
        max(l.is_ambiguous) = 1                                          as is_ambiguous
    from labelled as l
    left join session_device as d
        on d.customer_day_key = l.customer_day_key
       and d.session_seq      = l.session_seq
    group by l.customer_day_key, l.sales_code, l.customer_key, l.activity_date, l.scenario

),

-- orders per scenario, deduped (a resubmit logs the same increment_id twice)
scenario_orders as (

    select
        customer_day_key, scenario,
        count(*)                                                         as orders_submitted,
        sum(case when order_channel = 'PDA'          then 1 else 0 end)  as orders_keyed,
        sum(case when order_channel in ('WEB','APP') then 1 else 0 end)  as orders_received,
        array_agg(increment_id)                                          as order_ids
    from (
        select distinct customer_day_key, scenario, increment_id, order_channel
        from labelled
        where increment_id is not null
    ) as deduped
    group by customer_day_key, scenario

),

-- ── the FULL OUTER half: visits with no app activity at all ───────────────
visit_only as (

    select
        v.customer_day_key,
        v.sales_code,
        v.customer_key,
        v.activity_date,
        sum(v.on_site_minutes)                                           as on_site_minutes,
        max(v.is_ambiguous)                                              as is_ambiguous
    from presence as v
    left join by_scenario as a
        on a.customer_day_key = v.customer_day_key
    where a.customer_day_key is null
    group by v.customer_day_key, v.sales_code, v.customer_key, v.activity_date

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
        a.scenario, a.sessions,
        a.pda_minutes, a.ipad_minutes, a.android_tablet_minutes,
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
        0, 0, 0,
        v.on_site_minutes,
        cast(null as {{ dbt.type_string() }}[])                          as opened_at,
        cast(null as timestamp), cast(null as timestamp),
        0, 0, 0,
        cast(null as {{ dbt.type_string() }}[])                          as order_ids,
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

    c.pda_minutes,
    c.ipad_minutes,
    c.android_tablet_minutes,
    c.pda_minutes + c.ipad_minutes + c.android_tablet_minutes            as keying_minutes,
    c.on_site_minutes,

    c.opened_at,
    c.first_touch_local,
    c.last_touch_local,

    c.orders_submitted,
    c.orders_keyed,
    c.orders_received,
    c.order_ids,

    c.event_count,
    c.is_ambiguous,

    -- the standard noise filter: the rep spent measurable time, sent/handled an
    -- order, or was physically there. False only when none of those hold.
    -- Do NOT filter on event_count instead — `event_count >= 4` discards 31% of
    -- all orders, because a submit landing with no preceding cart activity is a
    -- legitimate one-event row.
    (c.pda_minutes + c.ipad_minutes + c.android_tablet_minutes > 0
     or c.orders_submitted > 0
     or coalesce(c.on_site_minutes, 0) > 0)                              as has_activity
from combined as c
left join reps as r
    on r.salesperson_code = c.sales_code
