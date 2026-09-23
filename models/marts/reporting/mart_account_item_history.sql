{{ config(materialized='table') }}

-- mart_account_item_history — ONE ROW PER ACCOUNT PER ITEM THEY HAVE BOUGHT.
-- "What does this account actually buy, what have they stopped buying, and what
-- are they due to reorder?"
--
--   Account | Item | Last bought | Times | Every N days | Status | In stock
--
-- The item-level companion to mart_rep_account_status, which stops at the
-- account. That table answers "who should I call"; this one answers "and what
-- do I say when they pick up".
--
-- ═══ THE TWO THINGS TO KNOW BEFORE READING A NUMBER ════════════════════════
--
-- 1. DOLLARS EXIST, BUT OVER A SHORTER PERIOD THAN EVERYTHING ELSE HERE. ADF
--    began exporting line amounts on 2026-09-20; earlier lines are NULL and
--    stay NULL, because the blob's historical seed carries the old column list
--    and the daily exports are deltas. So the DATES and FREQUENCY on this row
--    describe the whole relationship while sold_value describes only its recent
--    part. valued_purchase_days against times_purchased is how you tell how
--    much of the history the money covers — equal means all of it.
--
--    Never present a value total as though it matched the purchase count. "They
--    buy this every 5 weeks and have spent $400" is two different windows in
--    one sentence unless those two numbers agree.
--
-- 2. TWO CLOCKS, AND THEY ARE DIFFERENT DATES. purchase_as_of_date is NAV's
--    leading edge (the newest posted invoice); stock_snapshot_date is the
--    warehouse's (last night's snapshot). They advance on independent feed
--    schedules, so they genuinely differ, and both are published rather than
--    one being passed off as "today". Every purchase age is measured against
--    the first; in_stock is true as of the second. Say the relevant one out
--    loud in a spoken answer — an invoice that posted this morning is not in
--    here yet.
--
-- ═══ WHAT A ROW IS ═════════════════════════════════════════════════════════
-- An account-item pair with AT LEAST ONE POSTED PURCHASE. Items never bought
-- are deliberately absent — this is a history, and a row per account per
-- catalogue item would be millions of rows of nothing. What they have never
-- bought but plausibly should is mart_account_item_opportunities.
--
-- UOM IS COLLAPSED and only the dates survive that intact. See
-- int_customer_item_cadence: NAV records UOM as free text with no conversion
-- available, so quantities are reported for the account's PRIMARY UOM only and
-- quantity_uom_count flags when that hid something. Dates and frequencies are
-- UOM-independent and are exact.
--
-- HISTORY DEPTH IS THE ERP FEED'S, NOT THE EVENT LOG'S. This is the first mart
-- in the warehouse whose history does NOT start at
-- var('event_log_go_live_date') — it reaches back as far as the posted-invoice
-- export does, which is further. So an account can show a purchase history
-- here and no orders at all in mart_rep_account_status, and that is not a
-- contradiction: the two tables are fed by different systems over different
-- windows. Neither is wrong.
--
-- TEST AND INTERNAL ACCOUNTS ARE EXCLUDED, as in every other rep-facing mart.

{% set recent_days = var('account_item_recent_window_days') %}

with cadence as (

    select * from {{ ref('int_customer_item_cadence') }}

),

-- Rolling counts over the recent window, measured against the NAV clock so
-- they cannot disagree with the ages carried on the cadence rows.
recent_activity as (

    select
        p.customer_key,
        p.item_no,
        count(distinct case when p.sold_quantity > 0 then p.posting_date end) as purchases_recent,
        sum(p.sold_quantity)                                             as sold_quantity_recent_all_uoms,
        count(distinct p.quantity_uom)                                   as uoms_recent
    from {{ ref('int_customer_item_purchases') }} as p
    where p.posting_date >= {{ dbt.dateadd('day', -recent_days, nav_posted_today()) }}
    group by p.customer_key, p.item_no

),

accounts as (

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

items as (

    select
        item_no,
        item_label,
        item_category_code,
        item_category_name,
        product_group_code,
        base_uom,
        is_blocked,
        is_sellable,
        is_new_item,
        is_popular_item,
        is_on_promotion,
        promo_end_date,
        abc_class,
        has_wms_item,
        is_in_stock,
        shippable_qty,
        stock_snapshot_date
    from {{ ref('dim_items') }}

)

select
    -- ── who ───────────────────────────────────────────────────────────────
    c.customer_key,
    a.customer_name,
    a.owner_rep,
    a.owner_rep_name,
    -- The rep credited with this account's purchases of this item in NAV,
    -- which is NOT necessarily the rep who owns the account today — a book can
    -- change hands. Published beside owner_rep so the difference is visible
    -- rather than resolved into a single misleading column.
    c.sales_code                                                         as selling_rep,
    sr.rep_name                                                          as selling_rep_name,
    a.customer_is_active,
    a.city,
    a.county,
    a.post_code,
    a.customer_group,

    -- ── what ──────────────────────────────────────────────────────────────
    c.item_no,
    -- the name to READ OUT. Never say the item number to a rep.
    i.item_label,
    i.item_category_code,
    i.item_category_name,
    i.product_group_code,
    i.abc_class,

    -- ── the two as-of dates. See the header — they are different dates ────
    c.purchase_as_of_date,
    i.stock_snapshot_date,

    -- ── the history ───────────────────────────────────────────────────────
    c.first_purchase_date,
    c.last_purchase_date,
    c.days_since_last_purchase,
    c.times_purchased,
    c.invoice_count,
    coalesce(r.purchases_recent, 0)                                      as purchases_recent,

    -- ── the rhythm, derived from THIS pair's own gaps ─────────────────────
    -- NULL below var('account_item_min_purchases_for_cadence') purchases, where
    -- a median would be a single number wearing a statistic's clothes.
    -- reorder_status reads 'rhythm unknown' in that case rather than guessing.
    c.median_days_between_purchases,
    c.avg_days_between_purchases,
    c.min_days_between_purchases,
    c.max_days_between_purchases,
    c.expected_next_purchase_date,
    -- signed: negative means due in that many days, which is itself a reason
    -- to call today.
    c.days_overdue,

    -- ── the verdict ───────────────────────────────────────────────────────
    -- lapsed / overdue / due / not due / rhythm unknown, one reason per row.
    -- 'lapsed' IS the answer to "what have they stopped buying".
    c.reorder_status,
    c.reorder_priority,
    (c.reorder_status in ('lapsed', 'overdue', 'due'))                   as is_reorder_candidate,
    (c.reorder_status = 'lapsed')                                        as has_stopped_buying,

    -- ── quantities. PRIMARY UOM ONLY — see the header ─────────────────────
    c.primary_quantity_uom,
    c.quantity_uom_count,
    c.sold_quantity_primary_uom,
    c.avg_quantity_per_purchase,
    c.net_quantity_primary_uom,
    r.sold_quantity_recent_all_uoms,

    -- ── returns, in UNITS. No dollar rate exists ──────────────────────────
    -- A return RATE by value is what the business asked for ("any return over
    -- 2-3% should alert"). It is not computable: no posted NAV table carries an
    -- amount. This is the unit equivalent, and it is the honest substitute
    -- rather than a proxy dressed as the real thing.
    -- ── value. SHORTER WINDOW THAN THE DATES ABOVE — see the header ──────
    c.sold_value,
    c.returned_value,
    c.avg_value_per_purchase,
    -- how much of this relationship the money actually covers. Equal to
    -- times_purchased means all of it; lower means the value is recent only.
    c.valued_purchase_days,
    c.valued_line_count,
    c.line_count,

    c.cr_memo_count,
    c.returned_quantity_all_uoms,
    c.last_return_date,
    case
        when c.sold_quantity_primary_uom > 0
            then round(c.returned_quantity_all_uoms / c.sold_quantity_primary_uom, 4)
    end                                                                  as return_rate_units,
    -- THE RATE THE BUSINESS ACTUALLY ASKED FOR ("any return over 2-3%"), which
    -- was stated in money. Both sides come from the same covered window, so
    -- unlike return_rate_units this is a like-for-like ratio — but it exists
    -- only where that window has data, and is null otherwise rather than 0.
    case
        when c.sold_value > 0
            then round(coalesce(c.returned_value, 0) / c.sold_value, 4)
    end                                                                  as return_rate_value,

    -- ── can we actually ship it ───────────────────────────────────────────
    -- THREE-VALUED. null = the WMS mirror does not cover this item, so stock is
    -- UNKNOWN rather than zero. A consumer treating null as false will tell a
    -- rep an item is unavailable when the truth is that we cannot see it — the
    -- mirror covers warehouse CABOT only and an item may ship from elsewhere.
    i.is_in_stock,
    i.has_wms_item,
    i.shippable_qty,

    -- ── merchandising context, MANUAL FLAGS, not measured demand ──────────
    -- A buyer set these by hand; they are the pitch angle, not evidence. Useful
    -- here because "you are due to reorder this and it happens to be on promo"
    -- is the sentence a rep wants.
    i.is_on_promotion,
    i.promo_end_date,
    i.is_new_item,
    i.is_popular_item,
    i.is_sellable,
    i.is_blocked,

    -- ── when a call has to happen by ──────────────────────────────────────
    -- An account that only takes Tuesday deliveries has to be sold before
    -- Tuesday, so the reorder date alone is not actionable without this.
    -- delivery_day_count = 0 means NAV has no pattern on file — unknown, not
    -- "never delivers".
    a.delivery_days,
    a.delivery_day_count,
    a.appointment_required
from cadence as c
join accounts as a
    on a.customer_key = c.customer_key
left join items as i
    on i.item_no = c.item_no
left join recent_activity as r
    on r.customer_key = c.customer_key
   and r.item_no      = c.item_no
left join {{ ref('dim_reps') }} as sr
    on sr.sales_code = c.sales_code
