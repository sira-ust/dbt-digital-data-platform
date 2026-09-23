{{ config(materialized='table') }}

-- mart_rep_period_item_mix — ONE ROW PER REP PER PERIOD. What a rep's sales
-- were MADE OF: which categories, how much of it was promoted, new, or popular
-- stock, how much came back.
--
--   Period | Items | Lines | Accounts | Promo share | New share | Returns
--
-- THE COMPANION TO mart_rep_period_status, at the same grain and joined on
-- (sales_code, period_type, period_start). That table says how much a rep sold;
-- this one says what. They are SEPARATE MODELS ON PURPOSE and the reason is the
-- most important thing on this page:
--
-- ═══ A DIFFERENT FEED, A DIFFERENT CLOCK, AND DOLLARS THAT MEAN SOMETHING
--     ELSE ══════════════════════════════════════════════════════════════════
--
--   mart_rep_period_status   mysql event log -> fct_orders.
--                            ORDER value, as the rep submitted it. Order grain.
--                            History from var('event_log_go_live_date').
--                            as_of_date is rep_log_today().
--
--   this model               NAV ERP -> posted invoice and credit-memo lines.
--                            INVOICED value, as it posted. Line grain. Units
--                            span the whole ERP export; VALUE only reaches back
--                            to 2026-09-20. as_of_date is nav_posted_today().
--
-- BOTH NOW CARRY DOLLARS AND THEY ARE NOT THE SAME DOLLARS. One is what was
-- ordered, the other what was invoiced; they differ by cuts, short-ships and
-- posting lag, and they are keyed to different clocks. Quoting one as the other
-- is the single easiest mistake to make across these two tables.
--
-- The two as-of dates genuinely differ: invoices post days after an order is
-- keyed, on the ERP's own schedule. So THE TWO TABLES WILL NOT AGREE about a
-- period, and they are not supposed to. An order keyed on the 30th appears in
-- the rep's March value and in April's invoiced mix. Neither is wrong; they
-- measure different events. Publishing them as one row would hide that, and a
-- rep told "you sold $40k, 38% of it promo" would reasonably assume the 38%
-- was 38% of the $40k. IT IS NOT, AND IT CANNOT BE — see below.
--
-- ═══ TWO KINDS OF SHARE, AND THEY COVER DIFFERENT PERIODS ══════════════════
-- *_line_share    share of INVOICE LINES. Spans the whole export history.
-- *_value_share   share of DOLLARS. Only from 2026-09-20, when ADF began
--                 exporting Line Amount — earlier lines have no value and
--                 never will, so this is null or partial for older periods.
--
-- Both are published because neither substitutes for the other. A rep selling a
-- few high-value cases and many cheap ones has a line share that looks nothing
-- like a value share, and the business asked for value ("branded sales is
-- 40%"). But the value share is blind to most of the history, so for anything
-- before late September the line share is all there is.
--
-- The names carry the distinction on purpose — no column here is called plain
-- `share`. Check valued_lines against invoice_lines before quoting a value
-- share: when they differ, it describes only part of the period.
--
-- ═══ "BRANDED" IS NOT A COLUMN THE WAREHOUSE HAS ═══════════════════════════
-- The business asks for branded share. NAV's item master has no brand field —
-- not in the 33 columns the ADF job exports, and there is no brand table. The
-- nearest available cuts are item_category_code and product_group_code, which
-- are published below at full detail so the question can at least be asked by
-- category. Answering "what share was branded" needs either a brand column
-- added to the ADF export or a business-maintained seed mapping item to brand.
-- Nothing here approximates it, because an approximation of a brand split that
-- nobody can audit is worse than an honest absence.
--
-- ═══ WHAT COUNTS AS A LINE ═════════════════════════════════════════════════
-- A distinct item on a distinct invoice. Two lines of the same item on one
-- invoice count once, matching how int_customer_item_purchases treats an
-- item-day. Quantities are NOT summed across UOMs anywhere — NAV's UOM is free
-- text with no conversion available, so a cross-UOM total is true of nothing.
-- See int_customer_item_purchases for the full account of that.
--
-- SALES CREDITED AT LINE LEVEL. sales_invoice_line carries its own
-- salesperson_code and it wins over the header's: a line can be credited to a
-- different rep than the document, and the mix should follow the credit.

{% set periods = [
    {'name': 'day',     'trunc': 'day',     'unit': 'day',   'n': 1},
    {'name': 'week',    'trunc': 'week',    'unit': 'day',   'n': 7},
    {'name': 'month',   'trunc': 'month',   'unit': 'month', 'n': 1},
    {'name': 'quarter', 'trunc': 'quarter', 'unit': 'month', 'n': 3},
    {'name': 'year',    'trunc': 'year',    'unit': 'month', 'n': 12}
] %}

with purchases as (

    select
        p.sales_code,
        p.customer_key,
        p.item_no,
        p.posting_date,
        p.quantity_uom,
        p.sold_quantity,
        p.returned_quantity,
        p.invoice_count,
        p.cr_memo_count,
        p.sold_value,
        p.returned_value,
        p.line_count,
        p.valued_line_count
    from {{ ref('int_customer_item_purchases') }} as p
    -- Rep-attributable lines only. A null sales_code is a movement with no rep
    -- behind it and does not belong in a per-rep table.
    where p.sales_code is not null

),

items as (

    select
        item_no,
        item_category_code,
        item_category_name,
        product_group_code,
        is_new_item,
        is_popular_item,
        is_on_promotion,
        abc_class,
        category_is_fast_moving,
        category_is_slow_moving
    from {{ ref('dim_items') }}

),

-- The item attributes joined ONCE, before any period arithmetic, so the five
-- period types cannot pick up different item states.
--
-- A CAVEAT WORTH STATING: is_on_promotion and is_new_item in dim_items are
-- TODAY'S values, not the item's state on the posting date. NAV's promotion
-- lines do carry windows, so a point-in-time join is possible; it is not done
-- here because the merchandising flags (new_item, popular_item) have no history
-- at all — they are overwritten in place — so a point-in-time promo share
-- beside a current-state new share would be two different kinds of number in
-- adjacent columns. Both are current-state, consistently, and a promo share for
-- a period months ago should be read as "how much of that was stock we promote
-- NOW", which is a genuinely useful question and not the one it looks like.
lines_enriched as (

    select
        p.*,
        i.item_category_code,
        i.item_category_name,
        i.product_group_code,
        coalesce(i.is_new_item, false)                                   as is_new_item,
        coalesce(i.is_popular_item, false)                               as is_popular_item,
        coalesce(i.is_on_promotion, false)                               as is_on_promotion,
        coalesce(i.category_is_fast_moving, false)                       as category_is_fast_moving,
        coalesce(i.category_is_slow_moving, false)                       as category_is_slow_moving,
        (i.item_no is null)                                              as item_unknown
    from purchases as p
    left join items as i on i.item_no = p.item_no

),

-- ── the calendar, from the NAV feed's own days ────────────────────────────
-- Built from POSTING DATES, not from the event log's calendar. The two feeds
-- have different leading edges, and using the event log's would invent periods
-- the ERP has no data for and stop short of ones it does.
--
-- The zero-fill this gives is weaker than mart_rep_period_status's: that model
-- has an event on every day reps worked, whereas a day with no invoice posted
-- anywhere produces no row. In practice invoices post every business day, so
-- the gaps are weekends and holidays — visible as missing period_start values
-- at day grain, and immaterial at week and above.
calendar as (

    select distinct posting_date as activity_date
    from purchases

),

as_of as (

    select max(activity_date) as as_of_date from calendar

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

-- Every period type computed straight from the LINES, never rolled up from a
-- shorter period. Same discipline as mart_rep_period_status and for the same
-- reason: distinct counts do not roll up, so an item bought in two different
-- weeks is one item for the month and summing the weeks would say two.
period_mix as (

    select
        l.sales_code,
        dp.period_type,
        dp.period_start,
        dp.period_end,

        -- ── volume ────────────────────────────────────────────────────────
        -- A LINE is a distinct item on a distinct invoice-day; the underlying
        -- grain already collapses repeat lines of one item on one document.
        count(*)                                                         as invoice_lines,
        sum(l.invoice_count)                                             as invoice_documents,
        count(distinct l.item_no)                                        as distinct_items,
        count(distinct l.customer_key)                                   as accounts_invoiced,
        count(distinct l.item_category_code)                             as distinct_categories,

        -- ── the mix, as SHARES OF LINES. Never of value — see the header ──
        sum(case when l.is_on_promotion         then 1 else 0 end)       as promo_lines,
        sum(case when l.is_new_item             then 1 else 0 end)       as new_item_lines,
        sum(case when l.is_popular_item         then 1 else 0 end)       as popular_item_lines,
        sum(case when l.category_is_fast_moving then 1 else 0 end)       as fast_category_lines,
        sum(case when l.category_is_slow_moving then 1 else 0 end)       as slow_category_lines,
        -- lines whose item is not in dim_items at all. Normally 0; a non-zero
        -- value means posted invoices reference items the NAV item master does
        -- not carry, which makes every share below understate its numerator.
        -- Published rather than filtered so the fault is visible.
        sum(case when l.item_unknown            then 1 else 0 end)       as unknown_item_lines,

        -- ── the same mix, in DOLLARS. Shorter window — see the header ─────
        sum(l.sold_value)                                                as sales_value,
        sum(l.returned_value)                                            as returned_value,
        -- SOURCE lines, which is NOT invoice_lines. invoice_lines counts
        -- item-days (count(*) over this grain); these two sum the underlying
        -- invoice lines, of which one item-day can hold several. Comparing
        -- valued_lines against invoice_lines mixes the two grains and can make
        -- coverage exceed 1 — caught by a test on 18 rows before this comment
        -- existed.
        sum(l.line_count)                                                as source_lines,
        sum(l.valued_line_count)                                         as valued_lines,
        sum(case when l.is_on_promotion   then l.sold_value end)         as promo_value,
        sum(case when l.is_new_item       then l.sold_value end)         as new_item_value,
        sum(case when l.is_popular_item   then l.sold_value end)         as popular_item_value,

        -- ── returns, in LINES and UNITS. No value exists ──────────────────
        sum(l.cr_memo_count)                                             as cr_memo_documents,
        sum(case when l.returned_quantity > 0   then 1 else 0 end)       as returned_lines,

        -- ── quantity, NOT UOM-NORMALISED ──────────────────────────────────
        -- Summed across UOMs here, which is exactly what every other model in
        -- this chain refuses to do — so it is named to say so and paired with
        -- the UOM count that makes it interpretable. At rep-period grain the
        -- figure is a workload measure ("how many units did he move"), not a
        -- quantity of anything in particular, and a consumer seeing
        -- distinct_quantity_uoms > 1 must not present it as one.
        sum(l.sold_quantity)                                             as sold_quantity_mixed_uom,
        sum(l.returned_quantity)                                         as returned_quantity_mixed_uom,
        count(distinct l.quantity_uom)                                   as distinct_quantity_uoms
    from lines_enriched as l
    join day_periods as dp
        on dp.activity_date = l.posting_date
    group by l.sales_code, dp.period_type, dp.period_start, dp.period_end

)

select
    m.sales_code,
    r.rep_name,
    -- day / week / month / quarter / year. ALWAYS filter on this, or a query
    -- counts the same lines five times over.
    m.period_type,
    m.period_start,
    m.period_end,

    -- ── THE NAV CLOCK. Not mart_rep_period_status's as_of_date ────────────
    -- The newest posted invoice date. It lags the event log's leading edge by
    -- however long invoicing takes, so this table and mart_rep_period_status
    -- describe periods that are complete to DIFFERENT dates. Say which one an
    -- answer came from.
    a.as_of_date,
    (a.as_of_date >= m.period_start and a.as_of_date <= m.period_end)    as is_current,

    -- ── volume ────────────────────────────────────────────────────────────
    m.invoice_documents,
    m.invoice_lines,
    m.distinct_items,
    m.distinct_categories,
    -- DISTINCT accounts invoiced in the period. NOT summable across periods —
    -- ask for the longer period_type instead.
    m.accounts_invoiced,
    case
        when m.invoice_documents > 0
            then round(m.invoice_lines * 1.0 / m.invoice_documents, 2)
    end                                                                  as lines_per_invoice,

    -- ── THE MIX. Every one of these is a share of LINES, not of value ─────
    -- There is no value in the source, so there is no value share to be had.
    -- Read "0.38 promo_line_share" as "38% of the lines he invoiced were items
    -- we currently promote", never as 38% of his revenue.
    m.promo_lines,
    m.new_item_lines,
    m.popular_item_lines,
    m.fast_category_lines,
    m.slow_category_lines,
    case when m.invoice_lines > 0
         then round(m.promo_lines         * 1.0 / m.invoice_lines, 3) end as promo_line_share,
    case when m.invoice_lines > 0
         then round(m.new_item_lines      * 1.0 / m.invoice_lines, 3) end as new_item_line_share,
    case when m.invoice_lines > 0
         then round(m.popular_item_lines  * 1.0 / m.invoice_lines, 3) end as popular_item_line_share,
    case when m.invoice_lines > 0
         then round(m.fast_category_lines * 1.0 / m.invoice_lines, 3) end as fast_category_line_share,
    case when m.invoice_lines > 0
         then round(m.slow_category_lines * 1.0 / m.invoice_lines, 3) end as slow_category_line_share,

    -- Normally 0. Non-zero means posted invoices reference items the NAV item
    -- master does not carry, so every share above understates its numerator by
    -- up to this many lines. A denominator caveat, not a metric.
    m.unknown_item_lines,

    -- ── VALUE, AND THE SHARES THE BUSINESS ACTUALLY ASKED FOR ─────────────
    -- Only covers lines exported from 2026-09-20 onward. valued_lines against
    -- invoice_lines says how much of the period that is — equal means all of
    -- it, far below means these figures describe a slice. NULL rather than 0
    -- for a period entirely outside the window, because a period with no
    -- exported value has no value, not zero sales.
    m.sales_value,
    m.returned_value,
    m.source_lines,
    m.valued_lines,
    -- against SOURCE lines, not invoice_lines — see the note in period_mix.
    case when m.source_lines > 0
         then round(m.valued_lines * 1.0 / m.source_lines, 3) end        as value_coverage,
    case when m.sales_value > 0
         then round(m.promo_value        / m.sales_value, 3) end         as promo_value_share,
    case when m.sales_value > 0
         then round(m.new_item_value     / m.sales_value, 3) end         as new_item_value_share,
    case when m.sales_value > 0
         then round(m.popular_item_value / m.sales_value, 3) end         as popular_item_value_share,
    case when m.sales_value > 0
         then round(coalesce(m.returned_value, 0) / m.sales_value, 4) end as return_value_rate,

    -- ── returns, in LINES and UNITS ───────────────────────────────────────
    -- The business rule is "any return over 2-3% should alert". That rule was
    -- stated in money and money does not exist here, so this is the LINE
    -- equivalent and must be presented as such. A rep returning one expensive
    -- case and one cheap one scores the same on this as on nothing.
    m.cr_memo_documents,
    m.returned_lines,
    case when m.invoice_lines > 0
         then round(m.returned_lines * 1.0 / m.invoice_lines, 4) end     as return_line_rate,

    -- ── quantity. MIXED UOM — see the header and the column names ─────────
    m.sold_quantity_mixed_uom,
    m.returned_quantity_mixed_uom,
    -- above 1, the quantities above add cases to eaches. Check this before
    -- quoting either of them.
    m.distinct_quantity_uoms
from period_mix as m
cross join as_of as a
left join {{ ref('dim_reps') }} as r
    on r.sales_code = m.sales_code
