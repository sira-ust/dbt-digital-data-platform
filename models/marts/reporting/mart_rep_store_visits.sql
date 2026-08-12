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
-- elapsed time. Stints are measured in SECONDS and rounded to minutes once,
-- per device — see the stints CTE for why rounding per stint inflates.
--
-- KNOWN UNDERSTATEMENT: a stint holding one event spans 0 minutes, because
-- first and last are the same timestamp. event_count is published so a
-- dashboard can filter those out rather than averaging them in. Use the
-- has_activity flag for that, NOT event_count -- see its definition below. On
-- the real mirror ~26% of customer-days are a single event (mostly bare
-- order-list opens or a lone submit).
--
-- Full-rebuild table, NOT incremental: login boundaries shift as events land.

with visit_events as (

    select * from {{ ref('int_rep_store_visits') }}

),

-- ── device time: measure each stint, then fold stints up to the day ────────
stints as (

    -- Measured in SECONDS, deliberately, then rounded to minutes once at the
    -- end. dbt.datediff(...,'minute') compiles on Databricks to
    --   timestampdiff(minute, date_trunc('minute', a), date_trunc('minute', b))
    -- which counts minute BOUNDARIES CROSSED, not elapsed time: 20:57:57 ->
    -- 21:07:13 scores 10 despite only 9.27 minutes passing, and a two-second
    -- stint straddling a boundary scores a full minute. Rounding per stint and
    -- then summing compounded that — it moved 7,159 of 19,994 rows (36%).
    select
        customer_day_key,
        stint_seq,
        max(device)                                                      as device,
        {{ dbt.datediff('min(event_at_utc)', 'max(event_at_utc)', 'second') }}
                                                                         as stint_seconds
    from visit_events
    group by customer_day_key, stint_seq

),

device_time as (

    -- rounded per DEVICE (not per stint) so the three device columns always
    -- add up to keying_minutes, which is what anyone eyeballing a row checks
    select
        customer_day_key,
        cast(round(sum(case when device = 'PDA'            then stint_seconds else 0 end) / 60.0) as int) as pda_minutes,
        cast(round(sum(case when device = 'iPad'           then stint_seconds else 0 end) / 60.0) as int) as ipad_minutes,
        cast(round(sum(case when device = 'Android tablet' then stint_seconds else 0 end) / 60.0) as int) as android_tablet_minutes
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
-- order_channel splits orders the rep BUILT from orders that ARRIVED for him
-- to process. Verified on the real mirror 2026-08-13, a perfect split with no
-- crossover: the "Order List/Detail: Customer" codes carry only WEB (1,030)
-- and APP (946) orders, the "Sales" codes only PDA (8,795). So Customer/Sales
-- in the dev team's event names is WHO PLACED the order, not which screen —
-- a customer orders online, it lands with their rep, and his device logs
-- receiving it. That is why a customer-day can hold an order with 0 keying
-- minutes: there was nothing for him to key.
day_orders as (

    select
        customer_day_key,
        count(*)                                                         as orders_submitted,
        array_agg(increment_id)                                          as order_ids,
        sum(case when order_channel = 'PDA'          then 1 else 0 end)  as orders_keyed,
        sum(case when order_channel in ('WEB','APP') then 1 else 0 end)  as orders_received
    from (
        -- fct_orders is unique on increment_id, so this cannot fan out
        select distinct
            v.customer_day_key,
            v.increment_id,
            o.order_channel
        from visit_events as v
        left join {{ ref('fct_orders') }} as o
            on o.increment_id = v.increment_id
        where v.is_submit
          and v.increment_id is not null
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
    coalesce(o.orders_keyed, 0)                                          as orders_keyed,
    coalesce(o.orders_received, 0)                                       as orders_received,
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
     or coalesce(o.orders_submitted, 0) > 0)                             as has_activity
from days as d
left join device_time as v
    on v.customer_day_key = d.customer_day_key
left join login_times as s
    on s.customer_day_key = d.customer_day_key
left join day_orders as o
    on o.customer_day_key = d.customer_day_key
left join reps as r
    on r.salesperson_code = d.sales_code
