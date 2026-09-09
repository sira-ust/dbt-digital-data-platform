{{ config(materialized='table') }}

-- mart_rep_period_status — ONE ROW PER REP PER PERIOD, cumulative to date.
-- SALES AND ORDERS ONLY. "How am I doing?", at whatever granularity is asked.
--
--   Period | Elapsed | Orders | Value | Accounts | vs. last period | Pace
--
-- FIVE PERIOD TYPES IN ONE TABLE (period_type = day / week / month / quarter /
-- year), one row per period_start each. A DAY IS JUST THE SHORTEST PERIOD —
-- there is no separate daily table, because every column one would hold is the
-- same expression evaluated over a one-day window, and maintaining two models
-- that must agree is how they stop agreeing. "How did yesterday go" is
-- `period_type = 'day' and is_current`; "how is my month going" is
-- `period_type = 'month' and is_current`. Same columns, same meanings.
--
-- ALWAYS FILTER ON period_type. Without it a query sums the same orders five
-- times over. This is the one thing a consumer must get right, and it is one
-- equality test rather than a choice between five differently-named tables.
--
-- AS_OF_DATE IS THE CONTRACT, so read it first. The pipeline processes the
-- PREVIOUS day, so as_of_date is yesterday and yesterday is complete — there is
-- no partial "today" in this warehouse. "Month to date" therefore means "month
-- through as_of_date", and a rep asking at 10am is being told about a month
-- that ends last night. Say the date out loud in a spoken answer; it is the
-- caveat an assistant is most likely to drop.
--
-- days_elapsed and both projections are measured to as_of_date for the same
-- reason. Pacing against today's calendar date instead would divide by a day
-- whose data does not exist yet and report the entire team as behind, every
-- morning.
--
-- EVERYTHING HERE IS EXACT. It is a group by over fct_orders, which is itself
-- one row per submitted order parsed from the submit payload and deduped on
-- increment_id. No inference, no heuristics, nothing to caveat.
--
-- It carries NO store visits, on-site minutes, GPS, app time or device split,
-- and no scenario labels from mart_rep_customer_activity: those rest on the
-- geofence and idle-gap heuristics, which are not accurate enough yet to put in
-- front of a rep as a number. When the on-site algorithm is trusted, coverage
-- columns can be added here; until then their absence is the honest position,
-- not a gap.
--
-- GROUPED ON submitted_date_local, THE REP'S OWN DAY. fct_orders.submitted_date
-- is a UTC date and a 17:30 Pacific submit lands on the following day in it,
-- which at a month boundary moves revenue into the wrong month. fct_orders now
-- carries the rep-day column, so that costs nothing here.
--
-- WHAT CAN AND CANNOT BE SUMMED. Orders, value and line counts are additive
-- across periods of the same type. accounts_ordered IS NOT — a store that
-- ordered in week 1 and again in week 3 is ONE account, not two — which is
-- exactly why every period type is computed independently from the order rows
-- rather than a longer period being rolled up from shorter ones.
--
-- ZERO IS REPORTED AS ZERO. A rep gets a row for every period from his first
-- order onward, including the current one, even if he sold nothing in it.
-- Without that, "how is my month going" after a quiet month returns no row and
-- an assistant says "no data" when the honest answer is "nothing yet".
-- Zero-filling needs a calendar of periods that EXIST independently of whether
-- anyone sold in them, which is why the spine is built from the event log's
-- days and not from the order days — see the `calendar` CTE.
--
-- NO GOAL COLUMN YET, deliberately. Attainment needs a target this warehouse
-- does not have: NAV sales_quota_line is per ITEM in units whose UOM is marked
-- CONFIRM in the source docs, and the NAV feed carries no actuals to compare it
-- against (sales_line has quantity but no amount, and the replica has no
-- invoice or ledger table). order_value_projected below is a straight-line
-- PACE, not attainment. When a target source is agreed — confirmed NAV quota,
-- or a business-maintained seed — it joins on (sales_code, period_start).

{% set periods = [
    {'name': 'day',     'trunc': 'day',     'unit': 'day',   'n': 1},
    {'name': 'week',    'trunc': 'week',    'unit': 'day',   'n': 7},
    {'name': 'month',   'trunc': 'month',   'unit': 'month', 'n': 1},
    {'name': 'quarter', 'trunc': 'quarter', 'unit': 'month', 'n': 3},
    {'name': 'year',    'trunc': 'year',    'unit': 'month', 'n': 12}
] %}

with orders as (

    select
        sales_code,
        submitted_date_local                                             as activity_date,
        customer_key,
        order_channel,
        grand_total,
        total_item_count
    from {{ ref('fct_orders') }}
    -- Rep-attributable submits only. A null sales_code is an order with no rep
    -- behind it, and a null local date means no rep-day clock was computed for
    -- it — neither belongs in a per-rep table.
    where sales_code           is not null
      and submitted_date_local is not null

),

-- ── the calendar, and what "today" means ──────────────────────────────────
-- Every day the sales system was live, taken from the event log rather than
-- from the order days. THIS MATTERS: built from order days, a period in which
-- nobody happened to sell would produce no row at all, and "how did April go"
-- would answer "no data" instead of "nothing". The event log has a row on every
-- day reps were working, so every period in range exists and can be zero-filled.
--
-- The one case this cannot cover is a period with no sales events anywhere in
-- it — a full shutdown week — which would be absent rather than zero. Rare, and
-- visible as a gap in period_start rather than as a wrong number.
calendar as (

    select distinct rep_local_date                                       as activity_date
    from {{ ref('int_events_enriched') }}
    where actor_type     = 'sales'
      and rep_local_date is not null

),

-- The newest day the pipeline has processed, which is also the newest day that
-- is COMPLETE: the daily job lands the previous day's data, so the log's
-- leading edge is yesterday and yesterday is finished.
--
-- Taken from the DATA and not from current_date, which renders in the session
-- timezone — UTC on Databricks, the developer's zone on DuckDB — and would name
-- a different day in each. See macros/rep_log_today.sql.
as_of as (

    select max(activity_date) as as_of_date from calendar

),

-- ── every day mapped to the five periods it belongs to ────────────────────
-- Built once so the aggregate below picks up all five period grains from a
-- single join on activity_date, rather than repeating the date_trunc arithmetic
-- per period type.
--
-- prev_period_start is computed HERE, per branch, where period_type is a
-- literal — so "one period back" is one day for a day, 7 for a week and 3
-- months for a quarter, without a case expression having to re-derive which is
-- which.
day_periods as (

    {% for p in periods %}
    select
        c.activity_date,
        '{{ p.name }}'                                                   as period_type,
        cast({{ dbt.date_trunc(p.trunc, 'c.activity_date') }} as date)   as period_start,
        cast({{ dbt.dateadd('day', -1,
                 dbt.dateadd(p.unit, p.n,
                   dbt.date_trunc(p.trunc, 'c.activity_date'))) }} as date)
                                                                         as period_end,
        cast({{ dbt.dateadd(p.unit, -p.n,
                 dbt.date_trunc(p.trunc, 'c.activity_date')) }} as date)
                                                                         as prev_period_start
    from calendar as c
    {% if not loop.last %}union all{% endif %}
    {% endfor %}

),

all_periods as (

    select distinct period_type, period_start, period_end, prev_period_start
    from day_periods

),

-- ── the spine: every period from the rep's first order onward ─────────────
-- Zero-filled by construction. Periods BEFORE a rep's first order are excluded
-- rather than zero-filled, because "0 orders in March" for a rep who started in
-- June is a fact about the data, not about the rep.
rep_first_order as (

    select sales_code, min(activity_date) as first_order_date
    from orders
    group by sales_code

),

spine as (

    select
        r.sales_code,
        p.period_type,
        p.period_start,
        p.period_end,
        p.prev_period_start
    from rep_first_order as r
    join all_periods as p
        on p.period_end >= r.first_order_date

),

-- ── the metrics, every period type computed from the ORDER ROWS ───────────
-- Not rolled up from a shorter period, deliberately. accounts_ordered is a
-- distinct count and does not roll up: a store that ordered in two different
-- weeks is one account for the month, and summing the weekly figures would
-- call it two. Computing each period type straight from the orders makes that
-- correct by construction rather than by remembering to special-case it.
period_metrics as (

    select
        o.sales_code,
        dp.period_type,
        dp.period_start,
        count(*)                                                         as orders_submitted,
        sum(case when o.order_channel = 'PDA'          then 1 else 0 end) as orders_keyed,
        sum(case when o.order_channel in ('WEB','APP') then 1 else 0 end) as orders_received,
        count(distinct o.activity_date)                                  as days_with_orders,
        sum(o.grand_total)                                               as order_value_total,
        max(o.grand_total)                                               as order_value_largest,
        sum(o.total_item_count)                                          as order_line_count,
        -- DISTINCT accounts over the whole period. Never sum this across
        -- periods; ask for the longer period_type instead.
        count(distinct o.customer_key)                                   as accounts_ordered
    from orders as o
    join day_periods as dp
        on dp.activity_date = o.activity_date
    group by o.sales_code, dp.period_type, dp.period_start

),

assembled as (

    select
        s.sales_code,
        s.period_type,
        s.period_start,
        s.period_end,
        s.prev_period_start,
        a.as_of_date,

        coalesce(m.orders_submitted, 0)                                  as orders_submitted,
        coalesce(m.orders_keyed, 0)                                      as orders_keyed,
        coalesce(m.orders_received, 0)                                   as orders_received,
        coalesce(m.days_with_orders, 0)                                  as days_with_orders,
        -- null, not 0, when nothing was sold: a rep with no orders has no order
        -- value, and a 0 would average into a run rate as though it were one.
        m.order_value_total,
        m.order_value_largest,
        coalesce(m.order_line_count, 0)                                  as order_line_count,
        coalesce(m.accounts_ordered, 0)                                  as accounts_ordered
    from spine as s
    cross join as_of as a
    left join period_metrics as m on m.sales_code   = s.sales_code
                                 and m.period_type  = s.period_type
                                 and m.period_start = s.period_start

),

-- ── how far through the period are we, on COMPLETE data ───────────────────
-- least(as_of_date, period_end) is what makes a finished period read as fully
-- elapsed and the current one as partially elapsed, with no branch on which is
-- which. Elapsed to AS_OF_DATE, not to the wall clock.
elapsed as (

    select
        d.*,
        {{ dbt.datediff('period_start', 'period_end', 'day') }} + 1      as days_in_period,
        case
            when as_of_date < period_start then 0
            else {{ dbt.datediff('period_start',
                     'least(as_of_date, period_end)', 'day') }} + 1
        end                                                              as days_elapsed,
        (as_of_date >= period_start and as_of_date <= period_end)        as is_current
    from assembled as d

),

-- ── the previous period, STRICTLY the one before ──────────────────────────
-- Joined on prev_period_start rather than taken from lag(), because lag()
-- returns the previous period WITH A ROW, which after a gap is not last month
-- at all. Null therefore means "no comparison available", never "flat" — the
-- same rule mart_social_trending_items applies to its week-over-week movement.
compared as (

    select
        e.*,
        p.order_value_total                                              as prev_order_value_total,
        p.orders_submitted                                               as prev_orders_submitted,
        p.accounts_ordered                                               as prev_accounts_ordered
    from elapsed as e
    left join elapsed as p
        on  p.sales_code   = e.sales_code
        and p.period_type  = e.period_type
        and p.period_start = e.prev_period_start

)

select
    c.sales_code,
    r.rep_name,
    -- day / week / month / quarter / year. ALWAYS filter on this.
    c.period_type,
    c.period_start,
    c.period_end,
    -- The weekday NAME, and only for period_type = 'day' — for every other type
    -- period_start is a fixed weekday (weeks always start Monday) and the
    -- column would say nothing. The NAME rather than a number because DuckDB
    -- and Databricks number weekdays differently, so an integer silently shifts
    -- by a day between dev and prod.
    case
        when c.period_type = 'day' then {{ day_name('c.period_start') }}
    end                                                                  as day_of_week,

    -- ── the as-of contract ────────────────────────────────────────────────
    -- The newest day with COMPLETE data — yesterday, in normal operation,
    -- because the pipeline processes the previous day. Every cumulative number
    -- and both projections stop here.
    c.as_of_date,
    -- the period containing as_of_date. `period_type = 'month' and is_current`
    -- is the month-to-date row; `period_type = 'day' and is_current` is
    -- yesterday.
    c.is_current,
    c.days_in_period,
    -- calendar days of the period covered by complete data
    c.days_elapsed,
    round(c.days_elapsed * 1.0 / c.days_in_period, 3)                    as pct_period_elapsed,

    -- ── orders ────────────────────────────────────────────────────────────
    c.orders_submitted,
    -- how the order reached us. keyed = the rep typed it on the PDA;
    -- received = the customer placed it on web or the app and the rep handled
    -- it. Both published rather than one ratio, so a new channel appearing
    -- shows up as the two ceasing to sum.
    c.orders_keyed,
    c.orders_received,
    -- days in the period on which the rep sent at least one order. The
    -- denominator for a per-day average — days_elapsed includes weekends. Always
    -- 0 or 1 when period_type = 'day'.
    c.days_with_orders,

    -- ── value ─────────────────────────────────────────────────────────────
    c.order_value_total,
    case
        when c.orders_submitted > 0
            then round(c.order_value_total / c.orders_submitted, 2)
    end                                                                  as order_value_avg,
    c.order_value_largest,
    c.order_line_count,

    -- ── reach ─────────────────────────────────────────────────────────────
    -- DISTINCT accounts that ordered in the period. NOT summable across
    -- periods — ask for the longer period_type instead of adding shorter ones.
    c.accounts_ordered,

    -- ── pace ──────────────────────────────────────────────────────────────
    -- A STRAIGHT-LINE PROJECTION, not a forecast and not attainment: what the
    -- period would end at if the rest of it matched the rate so far. Divided by
    -- days_elapsed (complete data), never by today's date. Null for a finished
    -- period, which needs no projection. Degenerate but harmless at
    -- period_type = 'day', where it equals the actual.
    case
        when c.is_current and c.days_elapsed > 0
            then round(c.order_value_total * c.days_in_period / c.days_elapsed, 2)
    end                                                                  as order_value_projected,
    case
        when c.is_current and c.days_elapsed > 0
            then round(c.orders_submitted * 1.0 * c.days_in_period / c.days_elapsed, 1)
    end                                                                  as orders_submitted_projected,
    -- per SELLING day, so a short month or a week off does not read as a slump
    case
        when c.days_with_orders > 0
            then round(c.order_value_total / c.days_with_orders, 2)
    end                                                                  as order_value_per_selling_day,

    -- ── versus the period before ──────────────────────────────────────────
    -- STRICTLY the preceding period — the day before, the week before, the
    -- month before. Null = no comparison available, never flat. Comparing a
    -- PART-elapsed current period against a FULL previous one understates it by
    -- design, so pair these with pct_period_elapsed.
    c.prev_order_value_total,
    c.prev_orders_submitted,
    c.prev_accounts_ordered,
    case
        when c.prev_order_value_total > 0
            then round((c.order_value_total - c.prev_order_value_total)
                       / c.prev_order_value_total, 3)
    end                                                                  as order_value_change_pct
from compared as c
left join {{ ref('dim_reps') }} as r
    on r.sales_code = c.sales_code
