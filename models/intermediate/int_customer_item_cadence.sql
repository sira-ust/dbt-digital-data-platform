-- int_customer_item_cadence — one row per CUSTOMER x ITEM. How often this
-- account buys this item, when they last did, and when they are due again on
-- their OWN rhythm rather than on a company-wide rule.
--
-- THE POINT OF THE MODEL is the phrase "on that account's own rhythm". A
-- restaurant buying fish sauce every 3 weeks and a grocery buying it every 3
-- months are both perfectly healthy, and any fixed "overdue after N days"
-- threshold calls one of them lapsed. So the threshold here is DERIVED PER
-- CUSTOMER-ITEM from that pair's own purchase gaps. The business note asking
-- for "quarterly vs. monthly customer (some customer might need to be on
-- quarterly since we visit every other 6 weeks)" is answered by this column
-- rather than by a segmentation somebody has to maintain.
--
-- COLLAPSES THE UOM that int_customer_item_purchases keeps in its grain, and
-- three kinds of column survive that differently:
--   DATES and FREQUENCY  UOM-independent, computed across all UOMs, and they
--                        span the FULL export history
--   QUANTITY             restricted to the account's PRIMARY UOM, because
--                        adding cases to eaches is true of nothing.
--                        quantity_uom_count shows when that threw something away
--   VALUE                UOM-independent too (money is money), so totalled
--                        across every UOM — but only present from 2026-09-20,
--                        so it covers a SHORTER PERIOD than everything else here
--
-- That last asymmetry is the one to watch. times_purchased counts the whole
-- relationship; sold_value covers only its recent part. valued_purchase_days
-- sits beside times_purchased so the two can be compared rather than confused.
--
-- A GAP IS BETWEEN PURCHASE DAYS, and a purchase day means sold_quantity > 0.
-- A day carrying only a credit memo is NOT a purchase: without that rule, an
-- account returning something would have its "last bought" clock reset by the
-- return, and would look freshly active precisely when it was sending goods
-- back.
--
-- THREE PURCHASES MINIMUM BEFORE A RHYTHM IS PUBLISHED
-- (var account_item_min_purchases_for_cadence). Two purchases give exactly one
-- gap, and a median of one number is that number — an account that happened to
-- buy twice a fortnight apart would be declared a fortnightly buyer and then
-- reported overdue three weeks later. Below the floor the cadence columns are
-- NULL and reorder_status says so, which is a usable answer; a fabricated
-- rhythm is not.
--
-- MEASURED AGAINST THE NAV CLOCK, not the event log's — see
-- macros/nav_posted_today.sql. Invoices post on their own schedule, days after
-- an order is keyed and whether or not anyone opened the app, so ageing a
-- purchase against the app's leading edge would skew every number here by the
-- drift between two independent feeds.

{% set min_purchases = var('account_item_min_purchases_for_cadence') %}

with purchases as (

    select
        customer_key,
        item_no,
        posting_date,
        quantity_uom,
        sold_quantity,
        returned_quantity,
        net_quantity,
        invoice_count,
        cr_memo_count,
        sales_code,
        sold_value,
        returned_value,
        line_count,
        valued_line_count
    from {{ ref('int_customer_item_purchases') }}

),

-- ── the purchase DAYS, UOM collapsed ──────────────────────────────────────
-- One row per customer-item-day on which anything was actually sold. Returns
-- drop out entirely at this step: they are not purchases and must not enter the
-- gap series. Two UOMs bought on one day are one purchase day, not two.
purchase_days as (

    select
        customer_key,
        item_no,
        posting_date
    from purchases
    group by customer_key, item_no, posting_date
    having sum(sold_quantity) > 0

),

-- ── the gaps ──────────────────────────────────────────────────────────────
-- Days from the previous purchase day to this one. The first purchase has no
-- predecessor and yields a null gap, which median() ignores — so an account
-- with n purchases contributes n-1 gaps, exactly as it should.
gaps as (

    select
        customer_key,
        item_no,
        posting_date,
        {{ dbt.datediff(
             'lag(posting_date) over (partition by customer_key, item_no order by posting_date)',
             'posting_date', 'day') }}                                   as days_since_prev_purchase
    from purchase_days

),

cadence as (

    select
        customer_key,
        item_no,
        count(*)                                                         as times_purchased,
        min(posting_date)                                                as first_purchase_date,
        max(posting_date)                                                as last_purchase_date,
        {{ median('days_since_prev_purchase') }}                         as median_days_between_purchases,
        avg(days_since_prev_purchase)                                    as avg_days_between_purchases,
        min(days_since_prev_purchase)                                    as min_days_between_purchases,
        max(days_since_prev_purchase)                                    as max_days_between_purchases
    from gaps
    group by customer_key, item_no

),

-- ── the account's PRIMARY UOM for this item ───────────────────────────────
-- The UOM it has bought this item in on the most separate days. Ties broken by
-- quantity then alphabetically, so the pick is deterministic across runs and
-- across engines rather than whichever row came back first.
uom_ranked as (

    select
        customer_key,
        item_no,
        quantity_uom,
        count(distinct posting_date)                                     as uom_purchase_days,
        sum(sold_quantity)                                               as uom_sold_quantity,
        row_number() over (
            partition by customer_key, item_no
            order by count(distinct posting_date) desc,
                     sum(sold_quantity) desc,
                     quantity_uom
        )                                                                as _rn
    from purchases
    where sold_quantity > 0
    group by customer_key, item_no, quantity_uom

),

uom_summary as (

    select
        customer_key,
        item_no,
        count(*)                                                         as quantity_uom_count
    from uom_ranked
    group by customer_key, item_no

),

-- Quantities, restricted to the primary UOM. Deliberately NOT a total across
-- UOMs — see the header.
primary_uom_totals as (

    select
        p.customer_key,
        p.item_no,
        sum(p.sold_quantity)                                             as sold_quantity_primary_uom,
        sum(p.returned_quantity)                                         as returned_quantity_primary_uom,
        sum(p.net_quantity)                                              as net_quantity_primary_uom
    from purchases as p
    join uom_ranked as u
      on  u.customer_key  = p.customer_key
      and u.item_no       = p.item_no
      and u.quantity_uom  = p.quantity_uom
      and u._rn           = 1
    group by p.customer_key, p.item_no

),

-- Document and return counts across ALL UOMs — these are counts, not
-- quantities, so the UOM problem does not touch them.
document_totals as (

    select
        customer_key,
        item_no,
        sum(invoice_count)                                               as invoice_count,
        sum(cr_memo_count)                                               as cr_memo_count,
        sum(returned_quantity)                                           as returned_quantity_all_uoms,
        max(case when returned_quantity > 0 then posting_date end)       as last_return_date,
        min(sales_code)                                                  as sales_code,

        -- ── VALUE. No primary-UOM restriction, unlike the quantities ──────
        -- Money is money whatever the pack size, so these total across every
        -- UOM the account buys the item in. Sparse, though: null before
        -- 2026-09-20 and permanently so, which is what the valued/total line
        -- counts beside them are for.
        sum(sold_value)                                                  as sold_value,
        sum(returned_value)                                              as returned_value,
        sum(line_count)                                                  as line_count,
        sum(valued_line_count)                                           as valued_line_count,
        count(distinct case when valued_line_count > 0 and sold_quantity > 0
                            then posting_date end)                       as valued_purchase_days
    from purchases
    group by customer_key, item_no

),

assembled as (

    select
        c.customer_key,
        c.item_no,
        {{ nav_posted_today() }}                                         as purchase_as_of_date,

        c.times_purchased,
        c.first_purchase_date,
        c.last_purchase_date,
        {{ dbt.datediff('c.last_purchase_date', nav_posted_today(), 'day') }}
                                                                         as days_since_last_purchase,

        -- Below the floor these stay NULL rather than being computed from one
        -- gap. reorder_status says why.
        case when c.times_purchased >= {{ min_purchases }}
             then round(c.median_days_between_purchases, 1) end          as median_days_between_purchases,
        case when c.times_purchased >= {{ min_purchases }}
             then round(c.avg_days_between_purchases, 1) end             as avg_days_between_purchases,
        c.min_days_between_purchases,
        c.max_days_between_purchases,

        u.quantity_uom_count,
        r.quantity_uom                                                   as primary_quantity_uom,
        t.sold_quantity_primary_uom,
        t.returned_quantity_primary_uom,
        t.net_quantity_primary_uom,

        d.invoice_count,
        d.cr_memo_count,
        d.returned_quantity_all_uoms,
        d.last_return_date,
        d.sales_code,
        d.sold_value,
        d.returned_value,
        d.line_count,
        d.valued_line_count,
        d.valued_purchase_days
    from cadence as c
    left join uom_summary        as u on u.customer_key = c.customer_key and u.item_no = c.item_no
    left join uom_ranked         as r on r.customer_key = c.customer_key and r.item_no = c.item_no
                                     and r._rn = 1
    left join primary_uom_totals as t on t.customer_key = c.customer_key and t.item_no = c.item_no
    left join document_totals    as d on d.customer_key = c.customer_key and d.item_no = c.item_no

),

-- ── when are they due, and how late are they ──────────────────────────────
-- expected_next_purchase_date is last purchase + the pair's own median gap.
-- days_overdue is signed: negative means not due yet, and that is a useful
-- number in its own right ("due in 4 days" is a reason to call today).
projected as (

    select
        a.*,
        -- CAST BACK TO DATE. dateadd over a date returns a TIMESTAMP on duckdb,
        -- so without this the column arrives as 2026-08-31 00:00:00 while
        -- last_purchase_date beside it is a plain date — and a consumer
        -- comparing the two, or rendering "due on", gets a spurious midnight.
        case when a.median_days_between_purchases is not null
             then cast({{ dbt.dateadd('day', 'cast(round(a.median_days_between_purchases, 0) as int)',
                                 'a.last_purchase_date') }} as date)
        end                                                              as expected_next_purchase_date,
        case when a.median_days_between_purchases is not null
             then a.days_since_last_purchase - a.median_days_between_purchases
        end                                                              as days_overdue
    from assembled as a

)

select
    p.customer_key,
    p.item_no,
    -- THE NAV CLOCK. Every age in this table is measured against it, and it is
    -- NOT the event log's today — see macros/nav_posted_today.sql.
    p.purchase_as_of_date,

    -- ── the history ───────────────────────────────────────────────────────
    p.times_purchased,
    p.first_purchase_date,
    p.last_purchase_date,
    p.days_since_last_purchase,
    p.invoice_count,

    -- ── the rhythm. NULL below the purchase floor, never guessed ──────────
    p.median_days_between_purchases,
    p.avg_days_between_purchases,
    p.min_days_between_purchases,
    p.max_days_between_purchases,
    p.expected_next_purchase_date,
    -- signed: negative = not due yet.
    round(p.days_overdue, 1)                                             as days_overdue,

    -- ── the verdict, ONE reason per row in precedence order ───────────────
    -- So a consumer reads out a cause instead of re-deriving one from five
    -- columns. 'rhythm unknown' is an honest answer and is kept distinct from
    -- 'not due' — the first means we cannot tell, the second means we can and
    -- they are fine.
    --
    -- 'lapsed' fires at var('account_item_lapsed_gap_multiple') times the
    -- account's own median gap, so a quarterly buyer has to miss roughly two
    -- quarters before anyone says they stopped. 'due' opens slightly BEFORE
    -- the expected date (account_item_due_window_pct) because a rep needs to
    -- call ahead of the reorder, not after it.
    case
        when p.median_days_between_purchases is null                     then 'rhythm unknown'
        when p.days_since_last_purchase
             >= p.median_days_between_purchases
                * {{ var('account_item_lapsed_gap_multiple') }}          then 'lapsed'
        when p.days_overdue > 0                                          then 'overdue'
        when p.days_since_last_purchase
             >= p.median_days_between_purchases
                * (1 - {{ var('account_item_due_window_pct') }})         then 'due'
        else 'not due'
    end                                                                  as reorder_status,
    -- 1 = act first. Mirrors reorder_status exactly so `order by` gives the
    -- pitch list without the consumer needing to know the precedence.
    case
        when p.median_days_between_purchases is null                     then 4
        when p.days_since_last_purchase
             >= p.median_days_between_purchases
                * {{ var('account_item_lapsed_gap_multiple') }}          then 1
        when p.days_overdue > 0                                          then 2
        when p.days_since_last_purchase
             >= p.median_days_between_purchases
                * (1 - {{ var('account_item_due_window_pct') }})         then 3
        else 5
    end                                                                  as reorder_priority,

    -- ── quantities. PRIMARY UOM ONLY ──────────────────────────────────────
    -- Restricted, not summed across UOMs — NAV's UOM is free text with no
    -- conversion, so a cross-UOM total is true of nothing. quantity_uom_count
    -- above 1 means this account buys this item in more than one UOM and these
    -- figures cover only the commonest.
    p.quantity_uom_count,
    p.primary_quantity_uom,
    p.sold_quantity_primary_uom,
    p.returned_quantity_primary_uom,
    p.net_quantity_primary_uom,
    case
        when p.times_purchased > 0 and p.sold_quantity_primary_uom is not null
            then round(p.sold_quantity_primary_uom / p.times_purchased, 2)
    end                                                                  as avg_quantity_per_purchase,

    -- ── returns, across all UOMs ──────────────────────────────────────────
    -- Counts and a rate in UNITS. There is no dollar return rate available:
    -- no posted NAV table carries an amount. The business rule about alerting
    -- on returns over 2-3% therefore runs on units until NAV exports value.
    p.cr_memo_count,
    p.returned_quantity_all_uoms,
    p.last_return_date,

    -- ── VALUE. PARTIAL COVERAGE, AND PERMANENTLY SO ───────────────────────
    -- Real money, but only for lines exported from 2026-09-20 onward. Every
    -- date and frequency column above spans the FULL history; these do not.
    -- Reading a value total as though it covered the same period as
    -- times_purchased is the mistake this pair of counts exists to prevent:
    -- when valued_line_count is below line_count, the value is a partial view.
    p.sold_value,
    p.returned_value,
    p.line_count,
    p.valued_line_count,
    -- purchase days that carry any value at all. Compare with times_purchased:
    -- equal means the value covers the whole relationship, lower means it
    -- covers only the recent part of it.
    p.valued_purchase_days,
    -- average spend per VALUED purchase — divided by valued_purchase_days, not
    -- times_purchased, so it is not deflated by the unvalued history.
    case
        when p.valued_purchase_days > 0
            then round(p.sold_value / p.valued_purchase_days, 2)
    end                                                                  as avg_value_per_purchase,

    p.sales_code
from projected as p
