{{ config(materialized='table') }}

-- mart_rep_account_status — ONE ROW PER REP PER ACCOUNT. ORDERS ONLY.
-- "Which of my accounts have stopped buying?"
--
--   Account | Owned | Last order | Days since | Orders 90d | Value 90d | Flag
--
-- SCOPE, deliberately narrow. Ordering history and NAV account attributes,
-- nothing else. No visit dates, no on-site minutes, no app-usage clock: those
-- rest on the geofence and idle-gap heuristics, which are not accurate enough
-- yet to tell a rep he has not called on someone. So this list answers the one
-- question the order data can answer exactly — who has gone quiet on revenue —
-- and stays silent on coverage rather than guessing at it.
--
-- SPINE is a union of two senses of "the rep's account":
--   owned    NAV assigns the account to this rep (dim_customers.owner_rep)
--   ordered  this rep has actually sold to it
-- Neither alone is right. An owned account that has never ordered is exactly
-- the row a to-do list exists to surface, and a rep can legitimately sell to a
-- colleague's account. is_owned_by_rep says which case a row is.
--
-- WHAT NULL MEANS, and it is not zero. A null last_order_date means NOTHING ON
-- RECORD in the observed window, which starts at var('event_log_go_live_date')
-- — not "never ordered in the history of the company". days_since_last_order is
-- null alongside it rather than some large number.
--
-- Test and internal accounts are excluded outright — this is a work list, and
-- OFF001 is the office.
--
-- Thresholds (var('rep_account_order_overdue_days')) are a CONVENTION awaiting a
-- conversation with the sales managers, not a measured break-point.

{% set recent_days = var('rep_account_recent_window_days') %}

with accounts as (

    select
        customer_key,
        customer_name,
        city,
        county,
        post_code,
        owner_rep,
        is_active                                                        as customer_is_active,
        delivery_days,
        delivery_day_count,
        appointment_required,
        customer_group
    from {{ ref('dim_customers') }}
    where not is_test_account

),

-- Dated on the REP's local day, straight off fct_orders — submitted_date is a
-- UTC date and would slip a late-afternoon submit into the next day.
order_history as (

    select
        sales_code,
        customer_key,
        max(submitted_date_local)                                        as last_order_date,
        min(submitted_date_local)                                        as first_order_date,
        count(*)                                                         as orders_all_time,
        sum(grand_total)                                                 as order_value_all_time,
        sum(case when submitted_date_local >= {{ dbt.dateadd('day', -recent_days,
                        rep_log_today()) }} then 1 else 0 end)           as orders_recent,
        sum(case when submitted_date_local >= {{ dbt.dateadd('day', -recent_days,
                        rep_log_today()) }}
                 then grand_total else 0 end)                            as order_value_recent
    from {{ ref('fct_orders') }}
    where sales_code           is not null
      and customer_key         is not null
      and submitted_date_local is not null
    group by sales_code, customer_key

),

spine as (

    select owner_rep as sales_code, customer_key
    from accounts
    where owner_rep is not null

    union

    select sales_code, customer_key from order_history

),

assembled as (

    select
        s.sales_code,
        s.customer_key,
        a.customer_name,
        a.city,
        a.county,
        a.post_code,
        a.owner_rep,
        -- NAV ownership, not "who last sold to it".
        (a.owner_rep = s.sales_code)                                     as is_owned_by_rep,
        a.customer_is_active,

        o.first_order_date,
        o.last_order_date,
        coalesce(o.orders_all_time, 0)                                   as orders_all_time,
        coalesce(o.orders_recent, 0)                                     as orders_recent,
        o.order_value_all_time,
        o.order_value_recent,
        -- null rather than 0 when nothing was ordered: an account with no orders
        -- has no average order value, not one of zero.
        case
            when coalesce(o.orders_all_time, 0) > 0
                then round(o.order_value_all_time / o.orders_all_time, 2)
        end                                                              as order_value_avg,

        a.delivery_days,
        coalesce(a.delivery_day_count, 0)                                as delivery_day_count,
        a.appointment_required,
        a.customer_group
    from spine as s
    left join accounts      as a on a.customer_key = s.customer_key
    left join order_history as o on o.sales_code   = s.sales_code
                                and o.customer_key = s.customer_key

),

-- Day counts measured against the log's own leading edge, so this table and
-- mart_rep_daily_status cannot disagree about what "today" is.
aged as (

    select
        d.*,
        {{ rep_log_today() }}                                            as as_of_date,
        {{ dbt.datediff('last_order_date', rep_log_today(), 'day') }}    as days_since_last_order
    from assembled as d

)

select
    a.sales_code,
    r.rep_name,
    a.customer_key,
    a.customer_name,
    a.city,
    a.county,
    a.post_code,

    a.owner_rep,
    a.is_owned_by_rep,
    a.customer_is_active,

    -- ── the order clock ───────────────────────────────────────────────────
    -- NULL = nothing on record since var('event_log_go_live_date'), NOT "never".
    a.first_order_date,
    a.last_order_date,
    a.days_since_last_order,
    a.orders_all_time,
    a.orders_recent,
    a.order_value_all_time,
    a.order_value_recent,
    a.order_value_avg,

    -- ── the delivery pattern ──────────────────────────────────────────────
    -- Actionable, not decorative: an account that only takes Tuesday deliveries
    -- has to be ordered before Tuesday, so it decides WHEN a call is worth
    -- making. delivery_day_count = 0 means NAV has no pattern on file — unknown,
    -- not "never delivers".
    a.delivery_days,
    a.delivery_day_count,
    a.appointment_required,
    a.customer_group,

    a.as_of_date,

    -- ── the to-do verdict ─────────────────────────────────────────────────
    -- ONE reason per account, in precedence order, so an assistant reads out a
    -- cause instead of re-deriving one from six columns. Ordering: an inactive
    -- account is not the rep's problem, an account that has never ordered is the
    -- biggest one, then one that has stopped.
    a.attention_reason,
    -- 1 = most urgent. Mirrors attention_reason exactly, so `order by
    -- attention_priority` gives the call list without the consumer needing to
    -- know the precedence.
    a.attention_priority,
    (a.attention_priority <= 2)                                          as needs_attention
from (
    select
        g.*,
        case
            when not coalesce(g.customer_is_active, false)      then 'inactive account'
            when g.orders_all_time = 0                          then 'no order on record'
            when g.days_since_last_order
                 > {{ var('rep_account_order_overdue_days') }}  then 'order overdue'
            else 'ok'
        end                                                              as attention_reason,
        case
            when not coalesce(g.customer_is_active, false)      then 9
            when g.orders_all_time = 0                          then 1
            when g.days_since_last_order
                 > {{ var('rep_account_order_overdue_days') }}  then 2
            else 5
        end                                                              as attention_priority
    from aged as g
) as a
left join {{ ref('dim_reps') }} as r
    on r.sales_code = a.sales_code
