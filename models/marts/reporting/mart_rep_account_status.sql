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
-- SPINE is a union of three senses of "the rep's account":
--   owned     NAV assigns the account to this rep (dim_customers.owner_rep)
--   invoiced  this rep has posted sales to it
--   ordered   this rep submitted an app order for it
-- None alone is right. An owned account that has never bought is exactly the
-- row a to-do list exists to surface, and a rep can legitimately sell to a
-- colleague's account. is_owned_by_rep says which case a row is.
--
-- ═══ TWO ORDER CLOCKS, AND THE INVOICE ONE IS AUTHORITATIVE ════════════════
-- This table used to date accounts from fct_orders alone — app submit events,
-- app channels only, history starting at var('event_log_go_live_date'). That
-- made an account that orders by phone or email and is invoiced normally read
-- "no order on record": attention priority 1, straight to the top of the call
-- list. A rep would be told to chase a customer who bought last week.
--
-- Posted invoices fix it. fct_invoices covers EVERY channel and reaches back
-- across the whole ERP export, so it is the real answer to "how long since this
-- account last ordered".
--
-- BOTH ARE PUBLISHED, because they answer different questions. Invoices lag
-- posting by days; app orders are same-day but partial. last_order_date is the
-- LATER of the two — the most recent evidence from either feed — and the
-- components sit beside it so any figure can be traced to its source.
--
-- VALUE IS NOT THE SAME AS COVERAGE. invoice_value_recent is null before
-- 2026-09-20 (ADF began exporting amounts then and history is never
-- revisited), while the invoice DATES and COUNTS are complete throughout. An
-- account can therefore show invoices and no invoiced value, and that is the
-- pipeline's limit, not a quiet account.
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
        owner_rep_name,
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

-- POSTED SALES, the authoritative order clock. Every channel, full history.
-- Dated on posting_date, which is NAV's own clock and NOT the rep-local day
-- the app orders above use — see the header on why both are published.
invoice_history as (

    select
        sales_code,
        customer_key,
        max(posting_date)                                                as last_invoiced_date,
        min(posting_date)                                                as first_invoiced_date,
        count(*)                                                         as invoices_all_time,
        sum(case when posting_date >= {{ dbt.dateadd('day', -recent_days,
                        nav_posted_today()) }} then 1 else 0 end)        as invoices_recent,
        -- VALUE, NOT COUNT, is the sparse one. Null before 2026-09-20 and
        -- permanently so; sum() ignores nulls, so this covers only the valued
        -- part of the window. The counts above are complete.
        sum(case when posting_date >= {{ dbt.dateadd('day', -recent_days,
                        nav_posted_today()) }}
                 then net_value end)                                     as invoice_value_recent,
        sum(net_value)                                                   as invoice_value_all_time
    from {{ ref('fct_invoices') }}
    where sales_code   is not null
      and customer_key is not null
      and posting_date is not null
    group by sales_code, customer_key

),

spine as (

    select owner_rep as sales_code, customer_key
    from accounts
    where owner_rep is not null

    union

    select sales_code, customer_key from order_history

    union

    select sales_code, customer_key from invoice_history

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
        a.owner_rep_name,
        -- NAV ownership, not "who last sold to it".
        (a.owner_rep = s.sales_code)                                     as is_owned_by_rep,
        a.customer_is_active,

        o.first_order_date                                               as first_app_order_date,
        o.last_order_date                                                as last_app_order_date,
        v.first_invoiced_date,
        v.last_invoiced_date,
        -- THE AUTHORITATIVE CLOCK: the later of the two feeds. An account that
        -- ordered in the app yesterday and was last invoiced in March reads as
        -- one day, which is the truthful answer to "how long since they ordered".
        greatest(
            coalesce(v.last_invoiced_date, o.last_order_date),
            coalesce(o.last_order_date,    v.last_invoiced_date)
        )                                                                as last_order_date,
        coalesce(v.invoices_all_time, 0)                                 as invoices_all_time,
        coalesce(v.invoices_recent, 0)                                   as invoices_recent,
        v.invoice_value_recent,
        v.invoice_value_all_time,
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
    left join accounts        as a on a.customer_key = s.customer_key
    left join order_history   as o on o.sales_code   = s.sales_code
                                  and o.customer_key = s.customer_key
    left join invoice_history as v on v.sales_code   = s.sales_code
                                  and v.customer_key = s.customer_key

),

-- Day counts measured against the log's own leading edge, so this table and
-- mart_rep_daily_status cannot disagree about what "today" is.
aged as (

    select
        d.*,
        {{ rep_log_today() }}                                            as as_of_date,
        {{ nav_posted_today() }}                                         as invoice_as_of_date,
        -- Each age against ITS OWN feed's leading edge; the unified one against
        -- whichever feed has reached further, since that is the warehouse's
        -- best "today". Using the event log's edge alone would report an
        -- invoice posted after it as a NEGATIVE age.
        {{ dbt.datediff('last_invoiced_date', nav_posted_today(), 'day') }}
                                                                         as days_since_last_invoice,
        {{ dbt.datediff('last_app_order_date', rep_log_today(), 'day') }}
                                                                         as days_since_last_app_order,
        {{ dbt.datediff('last_order_date',
             'greatest(' ~ rep_log_today() ~ ', ' ~ nav_posted_today() ~ ')',
             'day') }}                                                   as days_since_last_order
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
    -- the OWNING rep's name. Distinct from rep_name above, which is the rep
    -- whose list this row appears on — they differ whenever a rep sells to a
    -- colleague's account, and a spoken answer needs to be able to say so.
    a.owner_rep_name,
    a.is_owned_by_rep,
    a.customer_is_active,

    -- ── the order clock ───────────────────────────────────────────────────
    -- NULL = nothing on record since var('event_log_go_live_date'), NOT "never".
    -- THE AUTHORITATIVE CLOCK: the later of the invoice and app-order feeds.
    a.last_order_date,
    a.days_since_last_order,

    -- ── posted sales. Every channel, full history ─────────────────────────
    a.first_invoiced_date,
    a.last_invoiced_date,
    a.days_since_last_invoice,
    a.invoices_all_time,
    a.invoices_recent,
    -- VALUE is null before 2026-09-20 even where the COUNTS are populated —
    -- ADF began exporting amounts then and history is never revisited. An
    -- account with invoices and no invoiced value is a pipeline limit, not a
    -- quiet account.
    a.invoice_value_recent,
    a.invoice_value_all_time,

    -- ── app orders. Same-day, but app channels only and from the event log's
    --    go-live. Kept beside the invoice clock rather than replaced: it is
    --    the fresher of the two and answers "did they order today".
    a.first_app_order_date,
    a.last_app_order_date,
    a.days_since_last_app_order,
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

    -- TWO LEADING EDGES, because two feeds. as_of_date is the event log's and
    -- is shared with every other rep mart; invoice_as_of_date is NAV's.
    a.as_of_date,
    a.invoice_as_of_date,

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
            -- BOTH feeds, deliberately. Keyed on app orders alone this said
            -- "no order on record" for every account that buys by phone or
            -- email — the false to-do item this rebase exists to remove.
            when g.invoices_all_time = 0
             and g.orders_all_time   = 0                         then 'no order on record'
            when g.days_since_last_order
                 > {{ var('rep_account_order_overdue_days') }}  then 'order overdue'
            else 'ok'
        end                                                              as attention_reason,
        case
            when not coalesce(g.customer_is_active, false)      then 9
            when g.invoices_all_time = 0
             and g.orders_all_time   = 0                         then 1
            when g.days_since_last_order
                 > {{ var('rep_account_order_overdue_days') }}  then 2
            else 5
        end                                                              as attention_priority
    from aged as g
) as a
left join {{ ref('dim_reps') }} as r
    on r.sales_code = a.sales_code
