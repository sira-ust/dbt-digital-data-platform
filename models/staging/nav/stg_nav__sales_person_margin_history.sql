-- stg_nav__sales_person_margin_history — ONE ROW PER POSTED DOCUMENT, with the
-- money on it. 61,997 rows, 2025-01-02 to 2026-10-07, $313.4M across 2,342
-- accounts and 21 rep codes.
--
-- ═══ THIS IS THE ONLY DOLLAR HISTORY IN THE WAREHOUSE ══════════════════════
-- stg_nav__sales_invoice_lines carries an amount only from 2026-09-20 and
-- 19,654,620 of its 19,696,349 rows are null forever. Measured for 2025-10: 10
-- of 130,188 invoice lines had an amount, while this table held all 2,715
-- documents for the same month. Anything asking what a rep sold more than
-- three weeks ago has no other source.
--
-- COVERAGE IS 1:1 WITH POSTED INVOICES, every month from 2025-01 —
-- 2,764/2,764 for Jan 2025, 2,715/2,715 for Oct 2025, 2,776/2,776 for Sep
-- 2026. 56,149 of the 56,320 invoice documents here tie back to a row in
-- sales_invoice_header; 171 (0.3%) do not and nobody has explained why. Small,
-- but it is why this is not treated as a substitute for the invoice tables —
-- it is a parallel measure of the same documents.
--
-- THE FLOOR IS 2025-01-02 AND IT IS HARD. Year-over-year works for any month in
-- 2026 and improves as time passes; 2024 and earlier simply are not here.
--
-- ═══ CREDIT MEMOS ARE SIGNED NEGATIVE HERE ════════════════════════════════
-- document_type 0 is an invoice (56,320 rows, +$313.4M), 1 is a credit memo
-- (5,677 rows, carrying POSITIVE amounts totalling $1.2M). NAV stores the
-- credit as a positive number and expects the reader to know the sign from the
-- type. Every amount below is flipped on type 1 so that SUM() nets without the
-- consumer having to remember — the alternative is a mart that silently
-- reports gross as net the first time someone forgets the CASE.
--
-- ═══ PERCENTAGES ARRIVE 0-1, AND ARE PUBLISHED THAT WAY ═══════════════════
-- brand_pct averages 0.5492 and invoice_margin_pct 0.1181 — 55% and 11.8%, not
-- 0.55% and 0.12%. They are NOT rescaled to 0-100 here: the paired NAV flags
-- ([Brand < 60%], [Invoice Margin < 13%]) are the only written record of the
-- company's thresholds, and keeping value and flag on the same scale is what
-- lets them be checked against each other.
--
-- THE PERCENTAGES ARE NOT RECOMPUTED. brand_pct is NAV's own and divides by
-- PRODUCT sales, not total sales — it matches brand/product on 50,572 of
-- 50,620 rows (99.9%) and brand/sales on 37,407 (74%). The business asked for
-- brand as a share of sales, so the mart derives that itself from the amounts;
-- this column is kept beside it so the two can be reconciled rather than one
-- quietly replacing the other.
--
-- WHAT 'BRAND' ACTUALLY MEANS IS STILL UNDEFINED. The amount is here, the rule
-- that produced it is in no NAV table and no documentation. We can report the
-- share; we cannot yet explain which items are in it.

with source as (

    select * from {{ source('nav', 'sales_person_margin_history') }}

),

typed as (

    select
        nullif(trim(cast(document_no as {{ dbt.type_string() }})), '')        as document_no,
        cast(posting_date as date)                                            as posting_date,

        -- NAV calls this 'Sales Person Code' here and 'Salesperson Code'
        -- everywhere else. Same code space; renamed to the house spelling so a
        -- join to dim_reps does not need to know which table it came from.
        nullif(trim(cast(sales_person_code as {{ dbt.type_string() }})), '')  as sales_code,
        nullif(trim(cast(customer_no as {{ dbt.type_string() }})), '')        as customer_key,

        cast(document_type as {{ dbt.type_int() }})                           as document_type,

        -- the sign every amount below is multiplied by. See the header.
        case when cast(document_type as {{ dbt.type_int() }}) = 1
             then -1 else 1 end                                               as sign,

        cast(sales_amount as {{ dbt.type_numeric() }})                        as sales_amount_raw,
        cast(cost_amount as {{ dbt.type_numeric() }})                         as cost_amount_raw,
        cast(brand_sales_amount as {{ dbt.type_numeric() }})                  as brand_sales_amount_raw,
        cast(product_sales_amount as {{ dbt.type_numeric() }})                as product_sales_amount_raw,

        cast(brand_pct as {{ dbt.type_numeric() }})                           as brand_pct_nav,
        cast(invoice_margin_pct as {{ dbt.type_numeric() }})                  as invoice_margin_pct_nav,
        cast(brand_below_target as {{ dbt.type_int() }})                      as brand_below_target_raw,
        cast(invoice_margin_below_target as {{ dbt.type_int() }})             as invoice_margin_below_target_raw,

        cast(loaddate as timestamp)                                           as loaded_at
    from source
    where nullif(trim(cast(document_no as {{ dbt.type_string() }})), '') is not null
      and cast(posting_date as date) is not null

)

select
    document_no,
    posting_date,
    sales_code,
    customer_key,

    document_type,
    (document_type = 1)                                                       as is_credit_memo,

    -- ── money, SIGNED so that SUM() nets ─────────────────────────────────
    -- NULL stays NULL. 4,051 of 61,997 rows have no sales_amount and a zero
    -- there would average into every margin figure downstream as though the
    -- goods had been given away.
    sales_amount_raw          * sign                                          as sales_amount,
    cost_amount_raw           * sign                                          as cost_amount,
    brand_sales_amount_raw    * sign                                          as brand_sales_amount,
    product_sales_amount_raw  * sign                                          as product_sales_amount,

    -- ── NAV's own ratios, 0-1, UNSIGNED and NOT recomputed ───────────────
    -- A ratio has no sign to flip: a credit memo's margin is still its margin.
    -- These describe the single document only; a period figure must be
    -- recomputed from the summed amounts, never averaged from these.
    brand_pct_nav,
    invoice_margin_pct_nav,
    (brand_below_target_raw = 1)                                              as brand_below_target,
    (invoice_margin_below_target_raw = 1)                                     as invoice_margin_below_target,

    -- marks the rows a value total can be built from, the same way
    -- stg_nav__sales_invoice_lines.has_value does.
    (sales_amount_raw is not null)                                            as has_value,

    loaded_at
from typed
