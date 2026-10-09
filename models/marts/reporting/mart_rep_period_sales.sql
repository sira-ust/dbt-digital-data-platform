{{ config(materialized='table') }}

-- mart_rep_period_sales — ONE ROW PER REP PER PERIOD. POSTED SALES DOLLARS,
-- THE TARGET, AND LAST YEAR. "Am I going to make my number?"
--
--   Period | Sold | Target | % there | On pace? | Margin | Branded % | vs LY
--
-- THE THIRD REP-PERIOD MART, and the three do not agree about a period on
-- purpose. Join on (sales_code, period_type, period_start) and READ EACH
-- TABLE'S OWN as_of_date:
--
--   mart_rep_period_status     mysql event log -> fct_orders.
--                              ORDERS SUBMITTED, as the rep keyed them.
--                              History from var('event_log_go_live_date').
--                              Clock: rep_log_today().
--
--   mart_rep_period_item_mix   NAV posted invoice and credit-memo LINES.
--                              What the month was MADE OF — categories, promo
--                              and new-item share. Units span the whole export;
--                              value only from 2026-09-20.
--                              Clock: nav_posted_today().
--
--   this model                 NAV Sales Person Margin History, DOCUMENT grain.
--                              WHAT POSTED, IN DOLLARS, against the target.
--                              History from 2025-01-02.
--                              Clock: max posting_date on this feed.
--
-- THREE FEEDS, THREE CLOCKS, THREE DOLLAR FIGURES, and quoting one as another
-- is the easiest mistake available here. An order keyed on the 30th is in the
-- rep's March orders and in April's posted sales. Neither is wrong.
--
-- WHY TARGETS ARE HERE AND NOT IN mart_rep_period_status: that table measures
-- ORDERS SUBMITTED THROUGH THE APP. The target is a sales target covering every
-- channel. Dividing app orders by it would tell a rep they are at 40% of
-- target while silently ignoring every phone and email order. Target belongs
-- beside the number it is actually a target for.
--
-- ═══ FOUR WAYS TO BE "AT" A TARGET, AND THEY ARE DIFFERENT NUMBERS ═════════
--   pct_of_period_target   sold / the WHOLE period's target. On the 8th of a
--                          month this is small by construction and is NOT a
--                          verdict. It answers "how much of my number is done".
--   pct_of_target_to_date  sold / the target for the days that have HAPPENED.
--                          THIS is "am I ahead or behind", and it is the one to
--                          read out. 1.0 means exactly on pace.
--   sales_projected        sold, scaled to the full period at the current rate.
--   pct_of_target_projected  where the rep lands if nothing changes.
--
-- On the 8th of October those four read roughly 0.31, 1.02, 1,100,000 and 1.02
-- for the same rep. A single "attainment" column would be one of them and the
-- reader would not know which.
--
-- ═══ BRANDED % DIVIDES BY TOTAL SALES, AS ASKED ════════════════════════════
-- brand_pct_of_sales = brand_sales_amount / sales_amount. That is what the
-- business specified.
--
-- NAV'S OWN FIGURE DIVIDES BY PRODUCT SALES INSTEAD and is published beside it
-- as brand_pct_nav_avg. The two differ because sales_amount includes freight,
-- CRV and pallet charges: NAV's brand_pct matches brand/product on 50,572 of
-- 50,620 documents (99.9%) and brand/sales on 37,407 (74%), and the amounts are
-- equal only on documents carrying no charges — 40,409 of 54,805, average gap
-- $222. Neither is wrong; they answer slightly different questions, and a rep
-- told "you are at 55%" deserves to have one definition behind it. Both are
-- here so the gap is visible rather than resolved by whoever writes the query.
--
-- WHAT COUNTS AS "BRAND" IS STILL UNDEFINED. The amounts come from NAV; the
-- rule that produced them exists in no table and no document. We can report the
-- share and we cannot yet explain it. The brand_below_target flag carries the
-- company's own 60% threshold, which is likewise written down nowhere else.
--
-- ═══ PRIOR YEAR: TWO FIGURES, AND ONLY ONE IS A DENOMINATOR ═══════════════
-- prev_year_sales          the WHOLE period one year earlier. Context.
-- prev_year_sales_to_date  the SAME ELAPSED WINDOW one year earlier. THIS is
--                          what sales_change_pct_vs_prev_year divides by.
--
-- For a closed period they are identical. For a period still running they are
-- not, and the first build of this model got it wrong: dividing October
-- month-to-date by all of last October reported Ryan Tran at -65.8% on the 7th,
-- when against the first seven days of October 2025 he was roughly flat. Exactly
-- the error already flagged on mart_rep_period_status.order_value_change_pct;
-- publishing both figures is what stops it being made again downstream.
--
-- The margin feed starts 2025-01-02, so 2026 periods have a counterpart and
-- 2025 ones do not. NULL, never zero: "down 100%" is the wrong answer to "we
-- have no data". Periods the feed cannot see into at all are not published —
-- int_rep_period_sales floors the spine at the first posting date, because six
-- years of "sold nothing against a $900,000 target" is worse than no row.
--
-- A rep whose book changed hands has a prior-year figure that is arithmetically
-- correct and commercially misleading — the accounts are not the same accounts.
-- mart_rep_account_status.is_owned_by_rep is the same underlying issue.
--
-- RATIOS ARE RECOMPUTED FROM SUMMED AMOUNTS, never averaged from the per
-- document percentages NAV supplies. Averaging a ratio across documents weights
-- a $200 credit memo the same as a $60,000 invoice.
--
-- ALWAYS FILTER ON period_type. Without it a query sums the same documents five
-- times over.

with periods as (

    select * from {{ ref('int_rep_period_sales') }}

),

reps as (

    select sales_code, rep_name from {{ ref('dim_reps') }}

)

select
    -- ── who ───────────────────────────────────────────────────────────────
    p.sales_code,
    -- NULL for codes NAV uses but the app has never issued a login to — 009,
    -- 020, 023 and 027 among the target codes. Published rather than filtered,
    -- so a nameless rep is visible instead of absent. See dim_reps.
    r.rep_name,

    -- ── when. FILTER ON period_type ───────────────────────────────────────
    p.period_type,
    p.period_start,
    p.period_end,
    p.as_of_date,
    p.is_current,
    -- how much of the period has happened, by TARGET DAYS rather than calendar
    -- days, so a period a rep had no target for cannot report a bogus elapsed
    -- fraction.
    case
        when p.target_days > 0
            then round(cast(p.target_days_elapsed as {{ dbt.type_numeric() }})
                     / p.target_days, 3)
    end                                                                  as pct_period_elapsed,

    -- ── what posted ───────────────────────────────────────────────────────
    -- Net of credit memos: staging signs them negative, so a bad month can
    -- legitimately be negative and that is not a bug.
    p.sales_amount,
    p.cost_amount,
    p.sales_amount - p.cost_amount                                       as gross_profit,
    p.document_count,
    p.credit_memo_count,
    p.accounts_sold,
    p.last_posting_date,
    -- how much of the period's money the amounts actually cover. Equal to
    -- document_count means all of it.
    p.valued_document_count,

    -- ── the number, and four honest ways to read it ───────────────────────
    -- ROUNDED TO CENTS. These are sums of daily_target, and daily_target is
    -- NAV's monthly figure divided by the days in the month and kept at 20
    -- decimal places — so summing 31 of them returns 1,079,999.999987 for a
    -- target that is exactly 1,080,000. Correct to the thirteenth decimal and
    -- unusable: an assistant reading it aloud says "one million seventy-nine
    -- thousand nine hundred and ninety-nine point nine nine". A dollar target
    -- is a dollar figure.
    round(p.period_target, 2)                                            as period_target,
    round(p.target_to_date, 2)                                           as target_to_date,
    p.has_target,

    -- THE TWO FIGURES THE BRIEF ASKS FOR IN WORDS: "you still need $25k" and
    -- "with 9 days left". Both are one subtraction away from the columns above,
    -- and leaving them to the caller is how two consumers end up computing
    -- "days left" off the calendar instead of off days a target was actually
    -- set for. Published so there is one answer.
    p.target_days,
    p.target_days - p.target_days_elapsed                                as target_days_remaining,
    case when p.period_target is not null
         then round(p.period_target - p.sales_amount, 2)
    end                                                                  as sales_still_needed,

    case when p.period_target > 0
         then round(p.sales_amount / p.period_target, 4)
    end                                                                  as pct_of_period_target,

    -- THE ONE TO READ OUT. 1.0 is exactly on pace.
    case when p.target_to_date > 0
         then round(p.sales_amount / p.target_to_date, 4)
    end                                                                  as pct_of_target_to_date,

    -- where the rep lands if the current rate holds. Null for a closed period,
    -- where the actual IS the answer and a projection would be noise.
    case
        when p.is_current and p.target_days_elapsed > 0
            then round(p.sales_amount
                     * cast(p.target_days as {{ dbt.type_numeric() }})
                     / p.target_days_elapsed, 2)
    end                                                                  as sales_projected,

    case
        when p.is_current and p.target_days_elapsed > 0 and p.period_target > 0
            then round((p.sales_amount
                      * cast(p.target_days as {{ dbt.type_numeric() }})
                      / p.target_days_elapsed) / p.period_target, 4)
    end                                                                  as pct_of_target_projected,

    -- ── margin and brand, RECOMPUTED from the summed amounts ─────────────
    case when p.sales_amount > 0
         then round((p.sales_amount - p.cost_amount) / p.sales_amount, 4)
    end                                                                  as margin_pct,

    -- AS THE BUSINESS ASKED: share of TOTAL sales, charges included.
    case when p.sales_amount > 0
         then round(p.brand_sales_amount / p.sales_amount, 4)
    end                                                                  as brand_pct_of_sales,

    -- NAV's own denominator, for reconciliation. See the header.
    case when p.product_sales_amount > 0
         then round(p.brand_sales_amount / p.product_sales_amount, 4)
    end                                                                  as brand_pct_of_product_sales,

    p.brand_sales_amount,
    p.product_sales_amount,

    -- the company thresholds, which are recorded in no other table
    case when p.sales_amount > 0
         then (p.brand_sales_amount / p.sales_amount) < 0.60
    end                                                                  as brand_below_target,
    case when p.sales_amount > 0
         then ((p.sales_amount - p.cost_amount) / p.sales_amount) < 0.13
    end                                                                  as margin_below_target,

    -- ── last year. TWO FIGURES, AND THE SECOND IS THE ONE TO DIVIDE BY ───
    -- prev_year_sales is the WHOLE period last year. Useful context, and
    -- WRONG as a denominator for a period still running.
    ly.sales_amount                                                      as prev_year_sales,
    -- prev_year_sales_to_date covers the SAME elapsed window last year. For a
    -- closed period the two are identical; for a month in progress they are
    -- not, and the gap is enormous. The first build of this model divided by
    -- the full prior month and reported Ryan Tran at -65.8% on the 7th of
    -- October — arithmetically correct, commercially nonsense, and the same
    -- error already flagged on mart_rep_period_status.order_value_change_pct.
    p.prev_year_sales_to_date,
    case
        when p.prev_year_sales_to_date > 0
            then round((p.sales_amount - p.prev_year_sales_to_date)
                     / p.prev_year_sales_to_date, 4)
    end                                                                  as sales_change_pct_vs_prev_year
from periods as p
left join reps as r
    on r.sales_code = p.sales_code
-- same rep, same period type, one year earlier. Joining on the date arithmetic
-- rather than a period index keeps a 53-week year and a leap day correct.
left join periods as ly
    on  ly.sales_code   = p.sales_code
    and ly.period_type  = p.period_type
    and ly.period_start = cast({{ dbt.dateadd('year', -1, 'p.period_start') }} as date)
