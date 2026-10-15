-- int_customer_invoice_rhythm — HOW OFTEN A STORE BUYS, and whether it is late.
-- One row per customer_key.
--
--   Store | Invoice days 12m | Usual gap | Days quiet | Past usual | Verdict
--
-- ═══ PER STORE, ACROSS EVERY SALES CODE. THIS IS THE WHOLE POINT ═══════════
-- The invoices_* columns on mart_rep_account_status count only the invoices
-- THIS rep billed for the account. Accounts get reassigned, so that is a
-- measure of the relationship, not of the shop.
--
-- PYONE CHO ASIA MARKET (PYO003) has 32 invoices under sales code 028 and none
-- under 032. On the rep's own column it has never bought anything; it is in
-- fact a going concern that someone else used to bill. 17 of Ryan Tran's 129
-- owned accounts are in that state.
--
-- A store's rhythm belongs to the store, whoever invoiced it. Everything here
-- is grouped on customer_key alone and sales_code is never referenced.
--
-- ═══ WHY THIS EXISTS: THE CALL LIST WAS RANKING THE WRONG SHOPS ════════════
-- The voice agent sorted its call list by days_since_last_order DESC. That
-- column is APP ORDERS ONLY, so the top of the list was whoever had been
-- quiet longest on one channel — for rep 032 that was six accounts with 2-5
-- invoices in their entire history, silent 150-270 days. Nothing to rescue.
--
-- Meanwhile KHUN ASIAN GROCERY STORE (KHU001) buys about every 28 days, had
-- been quiet 54 days, and was flagged 'ok'. That is the call worth making, and
-- it was invisible, because 54 days is unremarkable in absolute terms and
-- alarming only against ITS OWN 28-day habit.
--
-- Hence ratios, not day counts: days_past_usual compares a store to itself. A
-- weekly account 3 weeks quiet and a quarterly account 9 months quiet are the
-- same number here, which is what makes one sort order serve both.
--
-- ═══ DISTINCT DAYS, NOT INVOICE COUNT ═════════════════════════════════════
-- A store can be billed several times on one day — split shipments, a
-- correction, separate bill-to lines. Counting invoices would read that as
-- three visits to the shop and shorten its apparent gap. Every count here is
-- over DISTINCT posting dates.
--
-- ═══ THE MEDIAN GAP, NOT THE AVERAGE ══════════════════════════════════════
-- The stopgap the agent computes for itself uses span / (days - 1), which is a
-- mean and therefore moves with one long gap: a store that buys weekly but shut
-- for a six-week holiday reads as a fortnightly buyer ever after, and stops
-- looking late when it is. The median ignores that one outlier.
--
-- NULL BELOW THREE INVOICE DAYS, deliberately. Two invoice days give exactly
-- one gap, and one gap is not a habit — it is a pair of dates. Calling it a
-- rhythm would put a confident ratio against an account nobody can predict, so
-- usual_gap_days and days_past_usual are both null there and the status falls
-- through to 'occasional'.
--
-- On Databricks median() dispatches to percentile_approx. Approximate matters
-- for millions of rows; here each store contributes a handful of gaps and the
-- result is exact in practice. Flagged because the macro name hides it.
--
-- It does mean usual_gap_days can differ by half a day between targets on an
-- EVEN number of gaps: DuckDB's median() interpolates between the two middle
-- values and returns 28.5, while percentile_approx returns an actual observed
-- gap. Neither is wrong and the verdict bands are far wider than the
-- difference, but do not expect a dev number to match prod to the decimal.
--
-- ═══ MEASURED AGAINST NAV'S EDGE, NOT TODAY ═══════════════════════════════
-- The window ends at nav_posted_today() — the newest posting date in the ERP
-- replica — which is the same edge mart_rep_account_status publishes as
-- invoice_as_of_date. Using current_date would age every account by a day per
-- day whenever the ERP feed stalls, so a broken pipeline would look like every
-- customer lapsing at once. See the macro's own header.
--
-- The window is `>= edge - rhythm_window_days`, matching the convention the
-- rep_account marts already use for their rolling counts. That is 366 days
-- inclusive rather than 365; consistency with the sibling columns is worth more
-- here than the off-by-one.

{{ config(materialized='table') }}

{% set dormant_days      = var('rhythm_dormant_days') %}
{% set regular_min_days  = var('rhythm_regular_min_days') %}
{% set due_max_ratio     = var('rhythm_due_max_ratio') %}
{% set lapsing_max_ratio = var('rhythm_lapsing_max_ratio') %}

with invoice_days as (

    -- the grain this whole model rests on: one row per store per DAY it was
    -- invoiced, by anyone. See the header on why not per invoice.
    select distinct
        customer_key,
        posting_date                                                     as invoice_date
    from {{ ref('fct_invoices') }}
    where customer_key is not null
      and posting_date is not null

),

all_time as (

    select
        customer_key,
        count(*)                                                         as invoice_days_all_time,
        max(invoice_date)                                                as last_invoice_any_rep
    from invoice_days
    group by customer_key

),

windowed as (

    select *
    from invoice_days
    where invoice_date >= {{ dbt.dateadd('day', -var('rhythm_window_days'), nav_posted_today()) }}

),

gaps as (

    -- days between each invoice day and the one before it, within the window.
    -- The earliest day in the window has no predecessor and yields null, which
    -- median() drops — so N invoice days give N-1 gaps, as intended.
    select
        customer_key,
        {{ dbt.datediff(
             'lag(invoice_date) over (partition by customer_key order by invoice_date)',
             'invoice_date', 'day') }}                                   as gap_days
    from windowed

),

in_window as (

    select
        customer_key,
        count(*)                                                         as invoice_days_12m,
        -- fewer than three invoice days is not a habit. See the header.
        case when count(*) >= 3 then {{ median('gap_days') }} end        as usual_gap_days
    from gaps
    group by customer_key

),

measured as (

    select
        a.customer_key,
        a.invoice_days_all_time,
        a.last_invoice_any_rep,
        coalesce(w.invoice_days_12m, 0)                                  as invoice_days_12m,
        w.usual_gap_days,
        {{ dbt.datediff('a.last_invoice_any_rep', nav_posted_today(), 'day') }}
                                                                         as days_since_last_invoice_any_rep
    from all_time as a
    left join in_window as w
        on w.customer_key = a.customer_key

),

judged as (

    select
        m.*,

        -- how late this store is BY ITS OWN STANDARD. 1.0 = exactly its usual
        -- wait; 2.0 = twice it. Null wherever there is no established gap,
        -- never 0 — "we cannot say" and "bang on time" are opposite answers.
        case when m.usual_gap_days > 0
             then round(m.days_since_last_invoice_any_rep / m.usual_gap_days, 1)
        end                                                              as days_past_usual,

        case
            when m.invoice_days_12m >= {{ regular_min_days }} then 'regular'
            when m.invoice_days_12m >= 1                      then 'occasional'
            else 'none'
        end                                                              as buyer_type
    from measured as m

)

select
    j.customer_key,

    j.invoice_days_12m,
    j.invoice_days_all_time,
    j.last_invoice_any_rep,
    j.days_since_last_invoice_any_rep,
    j.usual_gap_days,
    j.days_past_usual,
    j.buyer_type,

    -- ── the verdict ──────────────────────────────────────────────────────
    -- Only a REGULAR gets a rhythm verdict, because only a regular has a
    -- rhythm to be off. A regular always has usual_gap_days: it needs 6 invoice
    -- days to qualify and the gap needs 3, so days_past_usual is never null on
    -- this branch.
    --
    -- The absolute backstop is tested FIRST. A store whose usual gap is 120
    -- days reaches 'dormant' at 180 days without ever passing 6x, and a store
    -- that buys weekly reaches it at 6x long before 180 — whichever fires
    -- first wins, which is the intent of having both.
    --
    -- Boundaries are inclusive upward: exactly 1.0 is 'due', exactly 1.5 is
    -- 'lapsing', exactly 6 is still 'lapsing'. Stated because a store sitting
    -- precisely on one is otherwise an argument waiting to happen.
    case
        when j.buyer_type = 'regular' then
            case
                when j.days_since_last_invoice_any_rep > {{ dormant_days }}
                  or j.days_past_usual > {{ lapsing_max_ratio }}   then 'dormant'
                when j.days_past_usual >= {{ due_max_ratio }}      then 'lapsing'
                when j.days_past_usual >= 1.0                      then 'due'
                else 'on rhythm'
            end
        -- not a regular NOW, but it used to be one: enough history to have had
        -- a habit, and long enough gone that losing it was an event rather than
        -- a slow month. Worth a call for a different reason — win-back, not
        -- rescue — so it ranks below every live account.
        when j.days_since_last_invoice_any_rep > {{ dormant_days }}
         and j.invoice_days_all_time >= {{ regular_min_days }}     then 'former regular'
        when j.buyer_type = 'occasional'                           then 'occasional'
        else 'no recent buying'
    end                                                                  as rhythm_status,

    -- sort key for the call list. Lapsing outranks due: a store half again
    -- past its usual wait is still in the habit of buying and can be caught,
    -- while one that is merely due may simply not have run out yet.
    -- Ties break on days_past_usual DESC in the consumer, not here.
    case
        when j.buyer_type = 'regular' then
            case
                when j.days_since_last_invoice_any_rep > {{ dormant_days }}
                  or j.days_past_usual > {{ lapsing_max_ratio }}   then 5
                when j.days_past_usual >= {{ due_max_ratio }}      then 1
                when j.days_past_usual >= 1.0                      then 2
                else 3
            end
        when j.days_since_last_invoice_any_rep > {{ dormant_days }}
         and j.invoice_days_all_time >= {{ regular_min_days }}     then 4
        else 5
    end                                                                  as rhythm_priority
from judged as j
