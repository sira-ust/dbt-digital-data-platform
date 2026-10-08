-- stg_nav__salesperson_targets — ONE ROW PER REP PER CALENDAR DAY. The rep's
-- number, and the only statement of one anywhere in this warehouse.
--
-- 48,944 rows, 2019-01-01 to 2026-12-31, 24 salesperson codes. Nothing else in
-- navrep, mysql or jdawms says what a rep is supposed to sell, so every
-- attainment figure downstream traces to this file.
--
-- ═══ READ daily_target, NOT monthly_target ═════════════════════════════════
-- monthly_target is populated ONLY on the 1st of each month — 1,418 of 48,944
-- rows carry a non-zero value and all of them fall on day 1. Every other day
-- reads 0, which is not a target of zero, it is an absence.
--
-- daily_target is populated throughout AND is exactly monthly_target divided by
-- the days in that month. Verified for October 2026: rep 032 carries
-- 34,838.71 a day and 1,080,000.00 for the month, and 34,838.71 x 31 =
-- 1,080,000.00 to the cent; summing all 20 reps gives 525,774.19 x 31 =
-- 16,299,000.00, likewise exact.
--
-- So A PERIOD'S TARGET IS THE SUM OF daily_target OVER ITS DATES. That prorates
-- correctly for a week, a quarter, or a month still in progress, and it never
-- needs the 1st-of-month row to exist. monthly_target is still published
-- because reading it back is the cheapest way to prove the identity still
-- holds if NAV ever changes how it fills these in.
--
-- ═══ last_year_sales IS NOT HERE, DELIBERATELY ═════════════════════════════
-- NAV has the columns and stopped maintaining them. last_year_sales is > 0 on
-- 2,750 rows and last_year_sales_month on 134 — every one of them dated 2019,
-- zero in all seven years since. Ingesting them would publish a column that
-- reads 0.00 for every rep and let a consumer report "last year you did
-- nothing". Prior-year comparison comes from int_rep_period_margin instead,
-- which has real posted dollars from 2025-01-02.
--
-- A ZERO daily_target IS NOT A TARGET. 7,060 of 48,944 rows carry 0 and a
-- further 49 are already null, which means no goal was set for that rep that
-- day — a rep who had not started, or had left. The zeros are published as NULL
-- so that summing a period cannot quietly dilute the average, and so
-- has_target says which rows are real.
--
-- CODE COVERAGE IS NOT COMPLETE. 20 of the 24 codes have a dim_reps row; 009,
-- 020, 023 and 027 do not. Same family as the 14 codes carried by
-- mart_rep_account_status with no rep record. Not filtered here — staging keeps
-- what NAV says and lets the join downstream show the gap.

with source as (

    select * from {{ source('nav', 'salesperson_target') }}

)

select
    -- NAV's [Date], renamed: `date` is reserved in Spark SQL and would need
    -- backticking in every model that touched it.
    cast(target_date as date)                                            as target_date,

    -- same code space as dim_reps.sales_code and as the sales_code on every
    -- event. Trimmed because NAV pads.
    nullif(trim(cast(salesperson_code as {{ dbt.type_string() }})), '')  as sales_code,

    -- ── the number. NULL, NOT ZERO, when no goal was set ─────────────────
    -- See the header: 0 here means "no target for this rep on this day", and
    -- averaging zeros into a period would report a goal nobody was given.
    nullif(cast(daily_target as {{ dbt.type_numeric() }}), 0)            as daily_target,

    -- carried for reconciliation only — 0 on every day but the 1st. Sum
    -- daily_target instead; the header shows the two agree exactly.
    nullif(cast(monthly_target as {{ dbt.type_numeric() }}), 0)          as monthly_target_on_first,

    (coalesce(cast(daily_target as {{ dbt.type_numeric() }}), 0) > 0)    as has_target,

    cast(loaddate as timestamp)                                          as loaded_at
from source
where cast(target_date as date) is not null
  and nullif(trim(cast(salesperson_code as {{ dbt.type_string() }})), '') is not null
