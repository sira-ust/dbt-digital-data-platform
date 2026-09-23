-- stg_nav__sales_cr_memo_lines — POSTED credit memo lines, one row per
-- document_no + line. The RETURN side of posted sales: what came back, from
-- whom, when, and against which invoice.
--
-- SHAPED TO MATCH stg_nav__sales_invoice_lines COLUMN FOR COLUMN
-- (customer_key, item_no, sales_code, posting_date, quantity, quantity_uom) so
-- int_customer_item_purchases can union the two and net them without a
-- per-source case expression. The source does NOT make this easy — the item
-- column is called cr_memo_item_no here, not item_no — and doing the rename
-- once, here, is why nothing downstream has to remember it.
--
-- QUANTITY ARRIVES POSITIVE and stays positive in `quantity`. The sign is
-- applied by the netting model, not here, because a returns count is a useful
-- number in its own right and a pre-negated column makes "how much came back"
-- read as a negative in every report that touches it.
--
-- line_type IS NOT FILTERED ON, deliberately. The source docs mark the NAV
-- [Type] enum CONFIRM — nobody has verified which integer means Item — and
-- guessing it would either drop real returns or admit freight credits as
-- product returns. Both are worse than carrying the column through and letting
-- the item-master join downstream be the gate, exactly as sales_invoice_line
-- (which has no line_type at all) already forces. Once the enum is confirmed,
-- filter HERE and the netting model needs no change.
--
-- VALUE, WITH THE SAME PARTIAL COVERAGE as the invoice side — ADF added Amount,
-- Line Amount and Unit Price here on 2026-09-20 too, and rows exported before
-- that stay null permanently. has_value marks which rows carry money.
--
-- THAT COVERAGE MUST BE CHECKED ON BOTH SIDES BEFORE QUOTING A RETURN RATE.
-- The business rule is "any return over 2-3% should alert", stated in money. A
-- ratio of valued returns to ALL sales — or valued sales to ALL returns —
-- mixes a partial numerator with a full denominator and understates or
-- overstates accordingly. Compare like with like: value against value over the
-- covered window, or units against units over the whole history. The unit
-- ratio remains the only one available for anything before 2026-09-20.

with source as (

    select * from {{ source('nav', 'sales_cr_memo_line') }}

)

select
    nullif(trim(cast(document_no as {{ dbt.type_string() }})), '')         as cr_memo_no,

    -- THE INVOICE BEING CREDITED, and there are two candidates. invoice_no is
    -- the line-level link and applies_to_doc_no is the header's; the source docs
    -- say they should agree where both are populated. The line one is taken here
    -- because it survives a credit that spans invoices. Expect nulls: a
    -- standalone credit references no invoice and can only net at customer
    -- level.
    nullif(trim(cast(invoice_no as {{ dbt.type_string() }})), '')          as applies_to_invoice_no,

    nullif(trim(cast(sell_to_customer_no as {{ dbt.type_string() }})), '') as customer_key,
    -- renamed from cr_memo_item_no ONCE, here — see the header.
    nullif(trim(cast(cr_memo_item_no as {{ dbt.type_string() }})), '')     as item_no,
    nullif(trim(cast(description as {{ dbt.type_string() }})), '')         as item_description_at_return,

    nullif(trim(cast(salesperson_code as {{ dbt.type_string() }})), '')    as sales_code,
    cast(posting_date as date)                                             as posting_date,

    -- POSITIVE. The netting model applies the sign.
    cast(quantity as {{ dbt.type_numeric() }})                             as quantity,
    nullif(trim(upper(cast(unit_of_measure as {{ dbt.type_string() }}))), '')
                                                                           as quantity_uom,

    -- ── value. ADDED TO THE EXPORT 2026-09-20, SO IT IS SPARSE ────────────
    -- NULL on every row exported before that date, which today is 19,654,620
    -- of 19,696,349 invoice lines. Not a defect and not temporary: the blob's
    -- historical seed carries the old column list and the daily exports are
    -- deltas, so history is never revisited. Only a re-export of the seed
    -- would fill it in.
    --
    -- NULL, NEVER COALESCED TO ZERO. A line with no exported amount has no
    -- value; a zero would average into every revenue figure downstream as
    -- though the goods had been given away. Consumers must decide what to do
    -- about the gap, and they can only do that if they can see it.
    cast(amount      as {{ dbt.type_numeric() }})                          as line_value,
    cast(line_amount as {{ dbt.type_numeric() }})                          as line_value_gross,
    cast(unit_price  as {{ dbt.type_numeric() }})                          as unit_price,
    (amount is not null)                                                   as has_value,

    -- ── the UOM conversion, at last ───────────────────────────────────────
    -- quantity_uom above is free text and joins to nothing. THIS is the code,
    -- and qty_per_uom is how many base units one of them is — so
    -- quantity * qty_per_uom finally makes a CASE line and an EA line
    -- comparable. Snapshotted at invoice time, so it reflects the pack size as
    -- it was then, not as it is now.
    nullif(trim(upper(cast(unit_of_measure_code as {{ dbt.type_string() }}))), '')
                                                                           as quantity_uom_code,
    cast(qty_per_unit_of_measure as {{ dbt.type_numeric() }})              as qty_per_uom,
    -- quantity restated in BASE units. Null when the factor is missing (rows
    -- predating the export change), which is the same window has_value covers.
    case
        when qty_per_unit_of_measure is not null
            then cast(quantity as {{ dbt.type_numeric() }})
                 * cast(qty_per_unit_of_measure as {{ dbt.type_numeric() }})
    end                                                                    as quantity_base,

    -- carried through unfiltered — see the header on the unconfirmed enum.
    cast(line_type as {{ dbt.type_int() }})                                as line_type,
    nullif(trim(cast(return_reason_code as {{ dbt.type_string() }})), '')  as return_reason_code,
    nullif(trim(cast(item_category_code as {{ dbt.type_string() }})), '')  as item_category_code,
    nullif(trim(cast(product_group_code as {{ dbt.type_string() }})), '')  as product_group_code,
    (coalesce(cast(is_frozen_item as {{ dbt.type_int() }}), 0) = 1)        as is_frozen_item,
    nullif(trim(cast(location_code as {{ dbt.type_string() }})), '')       as location_code,

    cast(loaddate as timestamp)                                            as loaded_at
from source
where cr_memo_item_no     is not null
  and sell_to_customer_no is not null
  and posting_date        is not null
