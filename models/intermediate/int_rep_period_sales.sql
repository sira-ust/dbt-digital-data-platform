-- int_rep_period_sales — ONE ROW PER REP PER PERIOD. Posted sales money, and
-- the target it is measured against, on the same spine and the same clock.
--
-- Raw measures only. Every ratio, projection and prior-year comparison is built
-- on top in mart_rep_period_sales, so there is exactly one place where a
-- percentage is defined.
--
-- ═══ WHY TARGETS AND ACTUALS SHARE ONE MODEL ═══════════════════════════════
-- They are different NAV tables with different shapes — targets are one row per
-- rep per calendar day stretching to 2026-12-31, actuals are one row per posted
-- document from 2025-01-02. Computing them separately means two period spines
-- that must agree about what "October" is, and that is how they stop agreeing.
-- One spine, built once, joined to both.
--
-- ═══ TWO TARGET COLUMNS, AND THE DIFFERENCE IS THE WHOLE POINT ═════════════
-- period_target   the FULL period's target, including days that have not
--                 happened yet. This is "my number" — the thing a rep is
--                 asked whether they will make.
-- target_to_date  only the days up to as_of_date. This is what they should
--                 have sold BY NOW.
--
-- Dividing actual by the first says how much of the month is done; dividing by
-- the second says whether they are ahead or behind today. A single "attainment"
-- column would be one of these silently, and on the 8th of the month the two
-- differ by a factor of four. Both are published and named for what they are.
--
-- Targets come from daily_target summed over the period's dates, never from
-- monthly_target — see stg_nav__salesperson_targets for why. Summing the daily
-- figure prorates a part-week or a part-month correctly and needs no special
-- case for any period type.
--
-- ═══ THE CLOCK IS NAV'S POSTING DATE ═══════════════════════════════════════
-- as_of_date is the newest posting_date in the margin history, NOT
-- current_date and NOT rep_log_today(). It is a THIRD clock, distinct from the
-- event log's (mart_rep_period_status) and from nav_posted_today()
-- (mart_rep_period_item_mix), because this feed lands on its own schedule.
-- Taken from the data for the same reason as everywhere else: current_date
-- renders in the session timezone and would name a different day on DuckDB
-- than on Databricks.
--
-- ═══ THE SPINE STARTS WHERE THE REP DOES ═══════════════════════════════════
-- A period is published for a rep from their first posted document or first
-- target onward, whichever came first. Periods before that are absent rather
-- than zero-filled: "$0 against a $1M target in March" for a rep who started in
-- June is a fact about the data, not about the rep.
--
-- A rep WITH a target and NO sales in a period IS published, with zero sales.
-- That row is the entire point of the table.
--
-- HISTORY FLOOR 2025-01-02. The margin feed does not reach earlier, so neither
-- does any period here. Prior-year comparison therefore works for 2026 periods
-- and returns nothing for 2025 ones.

{% set periods = [
    {'name': 'day',     'trunc': 'day',     'unit': 'day',   'n': 1},
    {'name': 'week',    'trunc': 'week',    'unit': 'day',   'n': 7},
    {'name': 'month',   'trunc': 'month',   'unit': 'month', 'n': 1},
    {'name': 'quarter', 'trunc': 'quarter', 'unit': 'month', 'n': 3},
    {'name': 'year',    'trunc': 'year',    'unit': 'month', 'n': 12}
] %}

with documents as (

    select
        sales_code,
        posting_date,
        sales_amount,
        cost_amount,
        brand_sales_amount,
        product_sales_amount,
        is_credit_memo,
        has_value,
        document_no,
        customer_key
    from {{ ref('stg_nav__sales_person_margin_history') }}
    where sales_code is not null

),

targets as (

    select sales_code, target_date, daily_target
    from {{ ref('stg_nav__salesperson_targets') }}
    where daily_target is not null

),

-- NAV's posting clock, AND the floor below which this feed sees nothing.
--
-- sales_floor matters as much as as_of_date. Targets run from 2019 and the
-- margin feed starts 2025-01-02, so without the floor the spine published six
-- years of periods carrying a real target and zero sales — "you sold nothing
-- against a $900,000 target in 2021", when the truth is that we have no sales
-- data for 2021 at all. Zero and unknown are not the same number and the
-- difference is the whole table's credibility.
as_of as (

    select max(posting_date) as as_of_date,
           min(posting_date) as sales_floor
    from documents

),

-- Every date either feed knows about, so one day->period map serves both.
-- Target dates run into the future; that is wanted, because a full-period
-- target has to include days that have not happened yet.
calendar as (

    select distinct posting_date as activity_date from documents
    union
    select distinct target_date  as activity_date from targets

),

day_periods as (

    {% for p in periods %}
    select
        c.activity_date,
        '{{ p.name }}'                                                   as period_type,
        cast({{ dbt.date_trunc(p.trunc, 'c.activity_date') }} as date)   as period_start,
        cast({{ dbt.dateadd('day', -1,
                 dbt.dateadd(p.unit, p.n,
                   dbt.date_trunc(p.trunc, 'c.activity_date'))) }} as date)
                                                                         as period_end
    from calendar as c
    {% if not loop.last %}union all{% endif %}
    {% endfor %}

),

all_periods as (

    select distinct period_type, period_start, period_end
    from day_periods

),

-- ── the spine ─────────────────────────────────────────────────────────────
-- Reps from BOTH feeds: one may have a target and no sales yet, another sales
-- under a code that was never given a target. Dropping either would hide the
-- case the table exists to surface.
rep_start as (

    select sales_code, min(first_date) as first_date
    from (
        select sales_code, min(posting_date) as first_date from documents group by sales_code
        union all
        select sales_code, min(target_date)  as first_date from targets   group by sales_code
    )
    group by sales_code

),

spine as (

    select
        r.sales_code,
        p.period_type,
        p.period_start,
        p.period_end
    from rep_start as r
    join all_periods as p
        on p.period_end >= r.first_date
    cross join as_of as a
    -- no period that has not started yet. A rep is not behind on December.
    where p.period_start <= a.as_of_date
      -- and no period the sales feed cannot see into. See the as_of CTE.
      and p.period_end  >= a.sales_floor

),

-- ── the SAME ELAPSED WINDOW one year earlier ──────────────────────────────
-- Comparing a month-to-date against a FULL month last year is the single
-- easiest way to make a rep look like they are collapsing. On 2026-10-07 Ryan
-- Tran had sold $339,406 of a $1,080,000 October; against all of October 2025
-- ($993,486) that reads as -65.8%, and against the first seven days of October
-- 2025 it reads as roughly flat. The first number is arithmetic; only the
-- second is an answer.
--
-- So for every period we also sum last year's documents over the SAME number
-- of elapsed days from the same point in the period. For a closed period the
-- window is the whole period and this equals the full prior-year figure, which
-- is why the mart can use one column for both cases.
prev_year_window as (

    select
        s.sales_code,
        s.period_type,
        s.period_start,
        sum(d.sales_amount)                                              as prev_year_sales_to_date
    from spine as s
    cross join as_of as a
    join documents as d
        on  d.sales_code = s.sales_code
        and d.posting_date >= cast({{ dbt.dateadd('year', -1, 's.period_start') }} as date)
        and d.posting_date <= cast({{ dbt.dateadd('year', -1,
                'least(a.as_of_date, s.period_end)') }} as date)
    group by s.sales_code, s.period_type, s.period_start

),

-- ── actuals, computed per period type straight from the documents ─────────
-- Not rolled up from a shorter period: accounts_sold is a distinct count and
-- does not roll up, so summing weekly figures would count a store twice.
period_actuals as (

    select
        d.sales_code,
        dp.period_type,
        dp.period_start,

        -- amounts are already signed in staging, so these net credit memos
        sum(d.sales_amount)                                              as sales_amount,
        sum(d.cost_amount)                                               as cost_amount,
        sum(d.brand_sales_amount)                                        as brand_sales_amount,
        sum(d.product_sales_amount)                                      as product_sales_amount,

        count(*)                                                         as document_count,
        sum(case when d.is_credit_memo then 1 else 0 end)                as credit_memo_count,
        sum(case when d.has_value then 1 else 0 end)                     as valued_document_count,
        count(distinct d.customer_key)                                   as accounts_sold,
        max(d.posting_date)                                              as last_posting_date
    from documents as d
    join day_periods as dp
        on dp.activity_date = d.posting_date
    group by d.sales_code, dp.period_type, dp.period_start

),

-- ── targets, summed over the period's days ────────────────────────────────
period_targets as (

    select
        t.sales_code,
        dp.period_type,
        dp.period_start,
        sum(t.daily_target)                                              as period_target,
        sum(case when t.target_date <= a.as_of_date
                 then t.daily_target end)                                as target_to_date,
        count(*)                                                         as target_days,
        sum(case when t.target_date <= a.as_of_date then 1 else 0 end)   as target_days_elapsed
    from targets as t
    join day_periods as dp
        on dp.activity_date = t.target_date
    cross join as_of as a
    group by t.sales_code, dp.period_type, dp.period_start

)

select
    s.sales_code,
    s.period_type,
    s.period_start,
    s.period_end,
    a.as_of_date,
    (a.as_of_date between s.period_start and s.period_end)               as is_current,

    -- ── actuals. ZERO, not null, where the rep sold nothing ──────────────
    -- A period on the spine is a period the rep existed for, so "no documents"
    -- genuinely means zero sold, unlike a missing target which means no goal
    -- was set.
    coalesce(pa.sales_amount, 0)                                         as sales_amount,
    coalesce(pa.cost_amount, 0)                                          as cost_amount,
    coalesce(pa.brand_sales_amount, 0)                                   as brand_sales_amount,
    coalesce(pa.product_sales_amount, 0)                                 as product_sales_amount,
    coalesce(pa.document_count, 0)                                       as document_count,
    coalesce(pa.credit_memo_count, 0)                                    as credit_memo_count,
    coalesce(pa.valued_document_count, 0)                                as valued_document_count,
    coalesce(pa.accounts_sold, 0)                                        as accounts_sold,
    pa.last_posting_date,

    -- ── targets. NULL where none was set — see the header ────────────────
    pt.period_target,
    pt.target_to_date,
    pt.target_days,
    pt.target_days_elapsed,
    (pt.period_target is not null)                                       as has_target,

    -- last year over the SAME elapsed window — see the prev_year_window CTE.
    -- NULL, never zero: before 2026 there is no prior year on this feed, and
    -- "down 100%" is the wrong answer to "we have no data".
    pyw.prev_year_sales_to_date
from spine as s
cross join as_of as a
left join period_actuals as pa
    on  pa.sales_code  = s.sales_code
    and pa.period_type = s.period_type
    and pa.period_start = s.period_start
left join period_targets as pt
    on  pt.sales_code  = s.sales_code
    and pt.period_type = s.period_type
    and pt.period_start = s.period_start
left join prev_year_window as pyw
    on  pyw.sales_code  = s.sales_code
    and pyw.period_type = s.period_type
    and pyw.period_start = s.period_start
