{{ config(materialized='table') }}

-- mart_account_period_status — ONE ROW PER ACCOUNT PER PERIOD. What this
-- customer bought, what came back, and whether the returns are out of line.
--
--   Account | Period | Invoices | Value | Returned | Return rate | Alert
--
-- THE TABLE BEHIND ONE SPECIFIC BUSINESS REQUEST: "last month sales for
-- customer ABC $1k, last month return from ABC is $200. Any return over 2-3%
-- should give some type of alert." Nothing else in the warehouse answers at
-- that grain — mart_rep_period_item_mix is per REP, and
-- mart_account_item_history is per account per ITEM over its lifetime.
--
-- FIVE PERIOD TYPES IN ONE TABLE (day / week / month / quarter / year), same
-- convention as mart_rep_period_status. ALWAYS FILTER ON period_type, or a
-- query sums the same invoices five times over.
--
-- ═══ NO ZERO-FILL, AND THAT IS A DELIBERATE DEPARTURE ══════════════════════
-- mart_rep_period_status gives a rep a row for every period from their first
-- order onward, so a quiet month reads as zero rather than "no data". This
-- table does NOT: a customer-period with no invoices produces no row.
--
-- The reason is arithmetic. There are 7,242 customers; zero-filling five period
-- grains across the whole export would generate millions of rows describing
-- nothing. An absent row means the account bought nothing in that period, and
-- an assistant can say so. The trade is real and it is the one case where this
-- table behaves differently from its rep-level sibling.
--
-- ═══ RETURNS ARE NETTED BY POSTING DATE, NOT BY INVOICE ════════════════════
-- A credit counts in the period it POSTS, not in the period of the invoice it
-- credits. That is what the business asked for — "last month's returns" means
-- credits raised last month — and it keeps this table immutable: a credit
-- posted today never rewrites a figure reported three months ago.
--
-- fct_invoices does the opposite, attaching each credit to the invoice it
-- credits, because it answers "what did this invoice end up being worth". Both
-- are right for their own question; the two will not agree on a period total
-- and are not supposed to.
--
-- ═══ VALUE IS PARTIAL; COUNTS ARE COMPLETE ═════════════════════════════════
-- ADF began exporting line amounts on 2026-09-20 and history is never
-- revisited, so invoice_value is NULL for older periods while invoice_count and
-- the dates are complete throughout. The return-rate alert therefore cannot
-- fire on older periods at all — return_rate_is_measurable says so explicitly,
-- because "no alert" must not be read as "returns are fine".

{% set periods = [
    {'name': 'day',     'trunc': 'day',     'unit': 'day',   'n': 1},
    {'name': 'week',    'trunc': 'week',    'unit': 'day',   'n': 7},
    {'name': 'month',   'trunc': 'month',   'unit': 'month', 'n': 1},
    {'name': 'quarter', 'trunc': 'quarter', 'unit': 'month', 'n': 3},
    {'name': 'year',    'trunc': 'year',    'unit': 'month', 'n': 12}
] %}

with invoices as (

    select
        customer_key,
        sales_code,
        posting_date,
        invoice_no,
        -- GROSS, deliberately. fct_invoices.net_value already subtracts the
        -- credits linked to each invoice; using it here would net the same
        -- credit twice, once by link and once by the posting-date aggregate
        -- below. Sales and returns are kept apart and combined once.
        invoice_value,
        line_count,
        item_count,
        has_value
    from {{ ref('fct_invoices') }}
    where customer_key is not null
      and posting_date is not null

),

-- Credits by the day they POSTED. Value is additive across items and UOMs, so
-- unlike a quantity this can safely be summed straight out of the item-day
-- grain.
credits as (

    select
        customer_key,
        posting_date,
        sum(returned_value)                                              as returned_value,
        sum(returned_quantity)                                           as returned_quantity
    from {{ ref('int_customer_item_purchases') }}
    where returned_quantity > 0
    group by customer_key, posting_date

),

-- ── the calendar, from the NAV feed's own days ────────────────────────────
-- Built from posting dates, so the periods that exist are the ones the ERP has
-- data for. as_of comes from nav_posted_today() for the same reason: this table
-- is fed entirely by NAV and must not be aged against the event log's clock.
calendar as (

    select distinct posting_date as activity_date from invoices

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
                                                                         as period_end,
        cast({{ dbt.dateadd(p.unit, -p.n,
                 dbt.date_trunc(p.trunc, 'c.activity_date')) }} as date)
                                                                         as prev_period_start
    from calendar as c
    {% if not loop.last %}union all{% endif %}
    {% endfor %}

),

-- Every period computed straight from the invoice rows, never rolled up from a
-- shorter period: distinct counts do not roll up, so an item bought in two
-- different weeks is one item for the month.
sales as (

    select
        i.customer_key,
        dp.period_type,
        dp.period_start,
        dp.period_end,
        dp.prev_period_start,

        count(distinct i.invoice_no)                                     as invoice_count,
        count(distinct i.posting_date)                                   as days_with_invoices,
        min(i.posting_date)                                              as first_invoice_date,
        max(i.posting_date)                                              as last_invoice_date,
        sum(i.line_count)                                                as line_count,
        sum(i.item_count)                                                as item_count_mixed,
        -- the rep credited with the most recent invoice in the period; min()
        -- where several share the grain, so the pick is deterministic
        min(i.sales_code)                                                as sales_code,
        count(distinct i.sales_code)                                     as sales_code_count,

        -- VALUE. Null before 2026-09-20 — see the header. sum() ignores nulls,
        -- so a period straddling that date returns the valued part only, which
        -- is what valued_invoice_count is here to expose.
        sum(i.invoice_value)                                             as invoice_value,
        sum(case when i.has_value then 1 else 0 end)                     as valued_invoice_count
    from invoices as i
    join day_periods as dp on dp.activity_date = i.posting_date
    group by i.customer_key, dp.period_type, dp.period_start,
             dp.period_end, dp.prev_period_start

),

returns_by_period as (

    select
        c.customer_key,
        dp.period_type,
        dp.period_start,
        sum(c.returned_value)                                            as returned_value,
        sum(c.returned_quantity)                                         as returned_quantity,
        count(distinct c.posting_date)                                   as days_with_returns
    from credits as c
    join day_periods as dp on dp.activity_date = c.posting_date
    group by c.customer_key, dp.period_type, dp.period_start

),

assembled as (

    select
        s.*,
        -- COALESCED TO ZERO, and here that is correct: this row exists because
        -- the account was invoiced in the period, so "no credit row" genuinely
        -- means nothing came back. Contrast invoice_value, where null means the
        -- amount was never exported and zero would be a lie.
        coalesce(r.returned_value, 0)                                    as returned_value,
        coalesce(r.returned_quantity, 0)                                 as returned_quantity,
        coalesce(r.days_with_returns, 0)                                 as days_with_returns
    from sales as s
    left join returns_by_period as r
        on  r.customer_key = s.customer_key
        and r.period_type  = s.period_type
        and r.period_start = s.period_start

),

-- Strictly the preceding period, joined on prev_period_start rather than taken
-- from lag() — lag() returns the previous period WITH A ROW, which for a
-- customer that skipped a month is not last month at all. Null therefore means
-- "no comparison available", never "flat". Same rule as mart_rep_period_status.
compared as (

    select
        a.*,
        p.invoice_value                                                  as prev_invoice_value,
        p.invoice_count                                                  as prev_invoice_count,
        p.returned_value                                                 as prev_returned_value
    from assembled as a
    left join assembled as p
        on  p.customer_key = a.customer_key
        and p.period_type  = a.period_type
        and p.period_start = a.prev_period_start

)

select
    c.customer_key,
    cu.customer_name,
    cu.owner_rep,
    cu.owner_rep_name,
    cu.is_active                                                         as customer_is_active,
    cu.city,
    cu.county,
    cu.customer_group,
    cu.store_type,

    -- the rep credited with these invoices, which is NOT necessarily the rep
    -- who owns the account today. Both are published.
    c.sales_code                                                         as selling_rep,
    sr.rep_name                                                          as selling_rep_name,
    c.sales_code_count,

    -- day / week / month / quarter / year. ALWAYS filter on this.
    c.period_type,
    c.period_start,
    c.period_end,
    -- NAV's leading edge, not the event log's. This table is fed entirely by
    -- posted invoices.
    {{ nav_posted_today() }}                                             as as_of_date,
    ({{ nav_posted_today() }} between c.period_start and c.period_end)   as is_current,

    -- ── what they bought ──────────────────────────────────────────────────
    -- Counts and dates are COMPLETE over the whole export.
    c.invoice_count,
    c.days_with_invoices,
    c.first_invoice_date,
    c.last_invoice_date,
    c.line_count,
    -- item_count summed across invoices, so an item bought on two invoices
    -- counts twice. Named to say so; there is no distinct-item count at this
    -- grain without re-reading the lines.
    c.item_count_mixed,

    -- ── value. PARTIAL — null before 2026-09-20 ───────────────────────────
    c.invoice_value,
    c.valued_invoice_count,
    -- how much of the period carries money. Below 1 means invoice_value
    -- describes only part of what was sold.
    case when c.invoice_count > 0
         then round(c.valued_invoice_count * 1.0 / c.invoice_count, 3) end as value_coverage,
    case when c.valued_invoice_count > 0
         then round(c.invoice_value / c.valued_invoice_count, 2) end     as invoice_value_avg,

    -- ── what came back, in the period it POSTED ───────────────────────────
    c.returned_value,
    c.returned_quantity,
    c.days_with_returns,

    -- ── THE ALERT ─────────────────────────────────────────────────────────
    -- "last month sales for ABC $1k, last month return from ABC is $200. Any
    -- return over 2-3% should give some type of alert." This is that, by value,
    -- as it was asked for.
    case when c.invoice_value > 0
         then round(c.returned_value / c.invoice_value, 4) end           as return_rate_value,
    -- THE HONESTY FLAG, and it is load-bearing. False means the period has no
    -- exported value, so no rate can be computed — which is NOT the same as
    -- returns being within tolerance. An assistant must not read a quiet flag
    -- as a clean bill of health on a period we cannot see.
    (c.invoice_value > 0)                                                as return_rate_is_measurable,
    (    c.invoice_value > 0
     and c.returned_value / c.invoice_value
         > {{ var('account_return_rate_alert_pct') }})                   as returns_over_threshold,

    -- ── versus the period before ──────────────────────────────────────────
    -- STRICTLY the preceding one. Null = no comparison available, never flat.
    c.prev_invoice_value,
    c.prev_invoice_count,
    c.prev_returned_value,
    case
        when c.prev_invoice_value > 0
            then round((c.invoice_value - c.prev_invoice_value)
                       / c.prev_invoice_value, 3)
    end                                                                  as invoice_value_change_pct
from compared as c
join {{ ref('dim_customers') }} as cu on cu.customer_key = c.customer_key
left join {{ ref('dim_reps') }} as sr on sr.sales_code = c.sales_code
where not cu.is_test_account
