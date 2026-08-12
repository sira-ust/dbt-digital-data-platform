-- mart_rep_store_visits — one row per REP x CUSTOMER x DAY.
-- Answers "on Monday, rep 001 worked these 6 stores, spending this many
-- minutes keying on each, at these times, and sent these orders".
--
--   6 stores on Monday  = 6 rows
--   10 minutes          = keying_minutes on that row
--   at x time, x time   = logged_in_at on that row (one HH:mm per login)
--
-- NOT A ROUTE. This aggregates app usage per customer; it does not sequence
-- the rep's day and makes no claim about physical presence. Sessions for
-- different customers legitimately overlap in wall-clock time because reps
-- work several open orders at once — 41% of customer switches on the real
-- mirror happen inside 60 seconds (2026-08-13). Sequencing that into a route
-- would be inventing a story the data does not tell; a physical visit would
-- need the GPS check-in (01040100), deliberately out of scope.
--
-- keying_minutes is APPROXIMATE: cart events carry no order number, so a
-- login is inferred from idle gaps (var('visit_gap_minutes'), 30). Exact on
-- every row: the customer, the device split, and orders_submitted / order_ids,
-- since the submit event names its order.
--
-- Device time is measured in STINTS — a run of consecutive events on one
-- device. PDA -> iPad -> PDA is three stints, each measured end to end, so a
-- handoff is never double-counted and keying_minutes stays under wall-clock
-- elapsed time.
--
-- KNOWN UNDERSTATEMENT: a stint holding one event spans 0 minutes, because
-- first and last are the same timestamp. event_count is published so a
-- dashboard can filter those out rather than averaging them in. Use the
-- is_reportable flag for that, NOT event_count -- see its definition below. On
-- the real mirror ~26% of customer-days are a single event (mostly bare
-- order-list opens or a lone submit).
--
-- Full-rebuild table, NOT incremental: login boundaries shift as events land.

with visit_events as (

    select * from {{ ref('int_rep_store_visits') }}

),

-- ── device time: measure each stint, then fold stints up to the day ────────
stints as (

    select
        customer_day_key,
        stint_seq,
        max(device)                                                      as device,
        {{ dbt.datediff('min(event_at_utc)', 'max(event_at_utc)', 'minute') }}
                                                                         as stint_minutes
    from visit_events
    group by customer_day_key, stint_seq

),

device_time as (

    select
        customer_day_key,
        sum(case when device = 'PDA'            then stint_minutes else 0 end) as pda_minutes,
        sum(case when device = 'iPad'           then stint_minutes else 0 end) as ipad_minutes,
        sum(case when device = 'Android tablet' then stint_minutes else 0 end) as android_tablet_minutes
    from stints
    group by customer_day_key

),

-- ── the "at x time, x time": one entry per LOGIN on that customer ─────────
sessions as (

    select
        customer_day_key,
        login_seq,
        min(event_at_local)                                              as login_at
    from visit_events
    group by customer_day_key, login_seq

),

login_times as (

    select
        customer_day_key,
        count(*)                                                         as login_count,
        -- sorted AFTER aggregating: array_agg gives no ordering guarantee, and
        -- ordering its input subquery does not survive (verified on Databricks,
        -- which returned "18:00, 17:11"). 'HH:mm' sorts lexically the same as
        -- chronologically, so a plain ascending sort is the correct fix.
        {{ sort_array('array_agg(' ~ format_hhmm('login_at') ~ ')') }}
                                                                         as logged_in_at
    from sessions
    group by customer_day_key

),

days as (

    select
        customer_day_key,
        max(sales_code)                                                  as sales_code,
        max(customer_key)                                                as customer_key,
        max(visit_date)                                                  as visit_date,
        min(event_at_local)                                              as first_touch_local,
        max(event_at_local)                                              as last_touch_local,
        count(*)                                                         as event_count
    from visit_events
    group by customer_day_key

),

-- Orders come from a PRE-FILTERED, pre-deduped set rather than
-- array_agg(distinct case when ...): array_agg keeps NULLs (verified on duckdb,
-- which returned [NULL, 'M000000002']) and array_agg(DISTINCT ...) is not
-- reliably portable. A resubmit logs the same increment_id twice; distinct
-- collapses it.
day_orders as (

    select
        customer_day_key,
        count(*)                                                         as orders_submitted,
        array_agg(increment_id)                                          as order_ids
    from (
        select distinct customer_day_key, increment_id
        from visit_events
        where is_submit and increment_id is not null
    ) as deduped
    group by customer_day_key

),

-- one display name per territory code (guard against join fan-out)
reps as (

    select
        salesperson_code,
        max(first_name || ' ' || last_name)                              as rep_name
    from {{ ref('stg_mysql__admin_users') }}
    where salesperson_code is not null
    group by salesperson_code

)

select
    d.customer_day_key,
    d.sales_code,
    r.rep_name,
    d.customer_key,
    d.visit_date,

    -- the headline: minutes actually keying on this customer that day
    coalesce(v.pda_minutes, 0)
        + coalesce(v.ipad_minutes, 0)
        + coalesce(v.android_tablet_minutes, 0)                          as keying_minutes,
    v.pda_minutes,
    v.ipad_minutes,
    v.android_tablet_minutes,

    -- when he worked it: one HH:mm per session, in time order
    s.login_count,
    s.logged_in_at,
    d.first_touch_local,
    d.last_touch_local,

    coalesce(o.orders_submitted, 0)                                      as orders_submitted,
    o.order_ids,
    d.event_count,

    -- The noise filter, defined once here instead of in every query.
    --
    -- NOT applied as a WHERE: a customer-day with no time and no order is real
    -- data (the rep opened the customer and did nothing — 7,297 abandoned
    -- Create Order clicks on the real mirror), and a churn or coverage question
    -- may well want those rows. Hiding them would also stop counts reconciling
    -- with fct_events.
    --
    -- Do NOT filter on event_count instead: `event_count >= 4` looks sensible
    -- but drops 4,503 orders — 31% of every order in this table — because a
    -- submit that lands with no preceding cart activity is a legitimate
    -- one-event row. This rule keeps 100% of orders and 100% of minutes, and
    -- drops only the 4,240 rows that carry neither (2026-08-13).
    (coalesce(v.pda_minutes, 0)
        + coalesce(v.ipad_minutes, 0)
        + coalesce(v.android_tablet_minutes, 0) > 0
     or coalesce(o.orders_submitted, 0) > 0)                             as is_reportable
from days as d
left join device_time as v
    on v.customer_day_key = d.customer_day_key
left join login_times as s
    on s.customer_day_key = d.customer_day_key
left join day_orders as o
    on o.customer_day_key = d.customer_day_key
left join reps as r
    on r.salesperson_code = d.sales_code
