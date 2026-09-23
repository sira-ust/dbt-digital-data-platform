-- stg_nav__sales_invoice_lines — POSTED sales invoice lines, one row per
-- document_no + line_no. Cast and trim only; no filtering beyond dropping rows
-- with no item, no customer or no date, which cannot participate in a history.
--
-- THIS IS THE SALES HISTORY. nav.sales_header / sales_line are OPEN documents
-- and a line vanishes from them the moment its order posts; this is where it
-- lands. Everything answering "what does this account actually buy" reads from
-- here.
--
-- VALUE EXISTS NOW, BUT ONLY FOR RECENT ROWS. ADF began exporting Amount,
-- Line Amount and Unit Price on 2026-09-20. Everything exported before that
-- has a NULL line_value, and — this is the part that matters — it will STAY
-- null. The blob keeps one historical seed file carrying the old column list,
-- and the daily exports are deltas of a few thousand lines, so nothing ever
-- revisits history. Measured 2026-09-23: 19,654,620 of 19,696,349 invoice
-- lines have no amount. Only a re-export of the seed changes that.
--
-- So this table is a FULL unit history and a PARTIAL value history, and the two
-- must not be confused. has_value marks which rows can be summed for revenue;
-- anything totalling line_value without filtering on it is adding real money to
-- a great deal of nothing. Prefer stating the window out loud.
--
-- THE UOM PROBLEM IS SOLVED, for the same window. unit_of_measure is still the
-- free text it always was, but unit_of_measure_code now arrives beside it with
-- qty_per_unit_of_measure, the conversion factor — so quantity_base finally
-- makes a CASE line and an EA line comparable. It is snapshotted at invoice
-- time, which beats today's value in item_unit_of_measure: it is the pack size
-- as it was when the sale happened. Null outside the coverage window, so the
-- (item_no, quantity_uom) grain downstream still earns its keep for older rows.
--
-- NO line_type COLUMN EXISTS on this table, unlike sales_line and
-- sales_cr_memo_line. So nothing here distinguishes an item line from a freight
-- charge or a comment; a non-item code in item_no simply fails to join to the
-- item master downstream. That join's coverage is the only guard available.
--
-- salesperson_code is taken from the LINE, not the header. A line can be
-- credited to a different rep than the document, and per-rep history should
-- follow the credit.

with source as (

    select * from {{ source('nav', 'sales_invoice_line') }}

)

select
    nullif(trim(cast(document_no as {{ dbt.type_string() }})), '')         as invoice_no,
    cast(line_no as {{ dbt.type_int() }})                                  as line_no,

    -- SELL-TO, not the header's bill-to. For a chain billed centrally these
    -- differ, and account history has to follow the store that bought it.
    -- Named customer_key to match the conformed key across mysql, jdawms and
    -- the rest of nav.
    nullif(trim(cast(sell_to_customer_no as {{ dbt.type_string() }})), '') as customer_key,
    nullif(trim(cast(item_no as {{ dbt.type_string() }})), '')             as item_no,
    nullif(trim(cast(description as {{ dbt.type_string() }})), '')         as item_description_at_sale,

    -- the rep CREDITED WITH THE LINE. Same code space as the sales_code on
    -- every event and as dim_reps.sales_code.
    nullif(trim(cast(salesperson_code as {{ dbt.type_string() }})), '')    as sales_code,

    -- posting_date arrives as a timestamp but means a DAY — NAV posts to a
    -- date, and the time component is an artefact of the export. Cast to date
    -- so it cannot drag a spurious hour into a date comparison.
    cast(posting_date as date)                                             as posting_date,

    cast(quantity as {{ dbt.type_numeric() }})                             as quantity,
    -- free TEXT, not a code — uppercased so 'Case' and 'CASE' do not become two
    -- grains. See the header on why nothing is converted.
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

    cast(loaddate as timestamp)                                            as loaded_at
from source
-- ── EMPTY STRING, NOT NULL. This filter reads the CLEANED value ───────────
-- NAV never writes NULL into these columns; it writes ''. The first version of
-- this filter tested the RAW column for null, so every blank row sailed through
-- and then became NULL via the nullif above -- 722,527 rows failing the
-- not_null test on customer_key, and 722,535 on item_no, none of which the
-- 200-row dev mock could produce. Test the same expression the column is built
-- from, or the filter and the output disagree.
--
-- WHAT IS ACTUALLY DROPPED, measured 2026-09-23: 722,535 of 19,696,349 lines
-- (3.7%). 715,497 of those are two literal strings -- 'www.ustrading.com/NEW'
-- and '**BROWSE NEW ITEMS ONLINE**' -- printed comment lines, not sales. Of the
-- whole set only 238 carry an amount at all and they total $0.00, so nothing of
-- value leaves with them.
where nullif(trim(cast(item_no             as {{ dbt.type_string() }})), '') is not null
  and nullif(trim(cast(sell_to_customer_no as {{ dbt.type_string() }})), '') is not null
  and posting_date is not null
