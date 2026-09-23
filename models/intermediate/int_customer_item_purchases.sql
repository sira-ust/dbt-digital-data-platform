-- int_customer_item_purchases — what each account actually bought, one row per
-- CUSTOMER x ITEM x POSTING DATE x UOM. Posted invoice lines netted against
-- posted credit-memo lines.
--
-- THE FOUR-PART GRAIN IS DELIBERATE, and the UOM is the part that surprises
-- people. A line reading `quantity = 6, CASE` and one reading `quantity = 6,
-- EA` are six of genuinely different things; collapsing them would produce
-- "they bought 12", which is true of nothing. Keeping UOM in the grain makes
-- that VISIBLE as two rows rather than silently wrong as one.
--
-- THE GRAIN STAYS EVEN THOUGH A CONVERSION NOW EXISTS. From 2026-09-20 the
-- export carries qty_per_unit_of_measure, so sold_quantity_base restates the
-- movement in base units and IS addable across UOMs. But it is null for
-- everything older, so collapsing the grain on the strength of it would work
-- for recent rows and quietly lose the rest. Keep the grain; use the _base
-- columns when you need a single comparable number and can accept the window.
--
-- NETTING: a return is subtracted from the item-day it POSTS on, not from the
-- day of the sale it credits. NAV's credit memo does carry a link back to its
-- invoice (applies_to_invoice_no), so crediting the original day is technically
-- possible — it is not done because it would make this table retroactively
-- mutable: a return posted today would change a quantity reported three months
-- ago, and every figure derived from it. Posting-date netting keeps history
-- immutable and matches how the business already reads its own ledger.
--
-- ZERO-QUANTITY LINES ARE REAL AND ARE KEPT. 2,490,061 invoice lines carry
-- quantity = 0 against a real item (measured 2026-09-23) -- the item was
-- invoiced and nothing shipped, because it was cut or went out of stock between
-- order and pick. 4,473 more are negative. So an item-day can exist with
-- sold_quantity = 0 and no return against it at all, and 2,438,623 of them do.
--
-- They are kept because "invoiced, shipped nothing" is a real event and a
-- useful one: it is every cut line in the warehouse. is_purchase_day is what
-- separates them from an actual sale, and int_customer_item_cadence gates its
-- gap series on the same rule, so no reorder rhythm is polluted by a day on
-- which nothing moved.
--
-- THE CONSEQUENCE, and it must not be hidden: net_quantity CAN BE NEGATIVE on a
-- day whose returns exceed its sales, including days with no sale at all. That
-- is not a bug; it is a return posting on a day of its own. Downstream models
-- that ask "did they buy on this day" must test sold_quantity > 0, NOT
-- net_quantity > 0 — a lone credit memo is not a purchase, and treating it as
-- one would reset an account's "last bought" clock to the day it sent something
-- back.
--
-- VALUE ARRIVED 2026-09-20, AND IT IS SPARSE. sold_value / returned_value /
-- net_value carry real money, but only for lines exported from that date on.
-- Everything older is NULL and stays NULL — the blob's historical seed still
-- holds the old column list and the daily exports are deltas, so history is
-- never revisited. 19,654,620 of 19,696,349 invoice lines had no amount when
-- this was measured on 2026-09-23.
--
-- WHAT THAT MEANS FOR A SUM. sum() ignores nulls, so summing sold_value over a
-- period that straddles 2026-09-20 returns the valued part and says nothing
-- about the rest. valued_line_count and line_count sit beside it for exactly
-- that reason: when they differ, the value is a partial view of the quantity.
-- Read them together or state the window.
--
-- THE UNIT HISTORY IS STILL THE COMPLETE ONE. Dates, frequency and quantity
-- reach back over the whole export; only money is recent. Anything that must
-- cover all of history — reorder rhythm, last-bought, stopped-buying — should
-- keep using the quantity columns, and does.
--
-- WHY NOT item_ledger_entry, which is finer-grained and would need no netting:
-- this export of it has no entry_type column, so sales movements cannot be told
-- apart from receipts, transfers and adjustments, and its quantity is signed
-- across all of them. It is declared as a source and left unused for that
-- reason.

with invoice_lines as (

    select
        customer_key,
        item_no,
        posting_date,
        quantity_uom,
        sales_code,
        invoice_no,
        quantity,
        quantity_base,
        line_value,
        has_value
    from {{ ref('stg_nav__sales_invoice_lines') }}

),

-- Credit memos arrive with a POSITIVE quantity — the sign lives here, in the
-- one model that nets, rather than in staging where a positive "how much came
-- back" is the more useful column.
return_lines as (

    select
        customer_key,
        item_no,
        posting_date,
        quantity_uom,
        sales_code,
        cr_memo_no,
        quantity,
        quantity_base,
        line_value,
        has_value
    from {{ ref('stg_nav__sales_cr_memo_lines') }}

),

-- Union first, aggregate once. The alternative — aggregating each side then
-- full-outer-joining — needs a coalesce on all four grain columns and produces
-- a null-vs-zero muddle on days that have only returns. This way a
-- returns-only day is simply a row whose sold_quantity is 0.
movements as (

    select
        customer_key,
        item_no,
        posting_date,
        quantity_uom,
        sales_code,
        invoice_no                                                       as document_no,
        quantity                                                         as sold_quantity,
        cast(0 as {{ dbt.type_numeric() }})                              as returned_quantity,
        quantity_base                                                    as sold_quantity_base,
        cast(null as {{ dbt.type_numeric() }})                           as returned_quantity_base,
        line_value                                                       as sold_value,
        cast(null as {{ dbt.type_numeric() }})                           as returned_value,
        has_value
    from invoice_lines

    union all

    select
        customer_key,
        item_no,
        posting_date,
        quantity_uom,
        sales_code,
        cr_memo_no                                                       as document_no,
        cast(0 as {{ dbt.type_numeric() }})                              as sold_quantity,
        quantity                                                         as returned_quantity,
        cast(null as {{ dbt.type_numeric() }})                           as sold_quantity_base,
        quantity_base                                                    as returned_quantity_base,
        cast(null as {{ dbt.type_numeric() }})                           as sold_value,
        line_value                                                       as returned_value,
        has_value
    from return_lines

)

select
    m.customer_key,
    m.item_no,
    m.posting_date,
    -- part of the grain. See the header: NAV gives UOM as free text with no
    -- conversion available, so two UOMs for one item stay two rows.
    m.quantity_uom,

    -- ── what moved ────────────────────────────────────────────────────────
    sum(m.sold_quantity)                                                 as sold_quantity,
    sum(m.returned_quantity)                                             as returned_quantity,
    -- CAN BE NEGATIVE — a return posting on a day with no sale. Test
    -- sold_quantity > 0 to ask "did they buy", never this.
    sum(m.sold_quantity) - sum(m.returned_quantity)                      as net_quantity,

    -- ── the same movement in BASE UNITS ───────────────────────────────────
    -- Only populated where the conversion factor was exported (2026-09-20
    -- onward). Unlike the UOM-keyed quantities above, these ARE comparable
    -- across UOMs — a CASE row and an EA row of the same item can be added.
    sum(m.sold_quantity_base)                                            as sold_quantity_base,
    sum(m.returned_quantity_base)                                        as returned_quantity_base,

    -- ── VALUE. PARTIAL COVERAGE — see stg_nav__sales_invoice_lines ────────
    -- NULL before 2026-09-20 and permanently so. sum() ignores nulls, so a
    -- day mixing valued and unvalued lines returns the valued part only —
    -- which is why valued_line_count sits beside it. When that count is below
    -- line_count, this total covers only some of what was sold.
    sum(m.sold_value)                                                    as sold_value,
    sum(m.returned_value)                                                as returned_value,
    sum(m.sold_value) - coalesce(sum(m.returned_value), 0)               as net_value,

    -- ── how it moved ──────────────────────────────────────────────────────
    -- Invoice and credit-memo document counts, not line counts: two lines of
    -- the same item on one invoice are one purchase event, not two.
    count(distinct case when m.sold_quantity     > 0 then m.document_no end) as invoice_count,
    count(distinct case when m.returned_quantity > 0 then m.document_no end) as cr_memo_count,

    -- how much of this item-day carries a value at all. Below line_count means
    -- the value columns above are a partial picture of it.
    count(*)                                                             as line_count,
    sum(case when m.has_value then 1 else 0 end)                         as valued_line_count,

    -- The rep credited with the movement. Aggregated because one item-day can
    -- span documents credited to different reps — rare, but real when an
    -- account changes hands mid-period. min() makes the pick deterministic;
    -- sales_code_count exposes when it happened rather than hiding it, so a
    -- per-rep consumer can see that this row is not cleanly one rep's.
    min(m.sales_code)                                                    as sales_code,
    count(distinct m.sales_code)                                         as sales_code_count,

    -- True purchase day. The flag exists so no downstream model has to
    -- re-derive the sold_quantity > 0 rule and no downstream model gets it
    -- wrong by testing net_quantity instead.
    (sum(m.sold_quantity) > 0)                                           as is_purchase_day
from movements as m
group by m.customer_key, m.item_no, m.posting_date, m.quantity_uom
