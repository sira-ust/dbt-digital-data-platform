{{ config(materialized='table') }}

-- fct_invoices — ONE ROW PER POSTED SALES INVOICE. What was actually sold, as
-- it landed in the ledger, net of the credits raised against it.
--
--   Invoice | Account | Rep | Posted | Lines | Items | Value | Returned | Net
--
-- THE PDF ASKED FOR THIS TABLE BY NAME: "if it's about historical sales order,
-- it might be better to get from final information which is sales invoice
-- schema... we might have to check against returns that related to that
-- invoice as well". This is that table.
--
-- ═══ HOW IT DIFFERS FROM fct_orders, WHICH IT DOES NOT REPLACE ═════════════
--
--   fct_orders     what a rep SUBMITTED, from the app event log. Same-day, but
--                  app channels only, and history starts at
--                  var('event_log_go_live_date').
--   fct_invoices   what was INVOICED, from NAV. Every channel including phone
--                  and email, history back to 2008 — but it lags posting, and
--                  its VALUE only reaches back to 2026-09-20.
--
-- They will never tie out. An order is cut, short-shipped or posted days later;
-- an invoice may cover several orders or part of one. Quoting one as the other
-- is the easiest mistake to make across this pair, so say which you mean.
--
-- ═══ THE CUSTOMER COMES FROM THE LINES, NOT THE HEADER ═════════════════════
-- The header carries bill_to; the lines carry sell_to. A chain billed centrally
-- has one bill_to across many stores, so keying on the header would credit the
-- head office for every branch's purchases. customer_key here is the sell_to
-- from the lines, and sell_to_customer_count exposes the rare invoice that
-- spans more than one — which is a data-quality signal, not something to hide.
--
-- ═══ VALUE IS PARTIAL AND PERMANENTLY SO ═══════════════════════════════════
-- ADF began exporting line amounts on 2026-09-20. Older invoices have NULL
-- invoice_value and always will: the blob's historical seed carries the old
-- column list and the daily exports are deltas, so history is never revisited.
-- 19,654,620 of 19,696,349 lines had no amount when measured on 2026-09-23.
--
-- has_value marks which rows can be summed for revenue. NOTHING IS COALESCED TO
-- ZERO — an invoice with no exported amount has no value, and a zero would
-- average into every figure downstream as though the goods were given away.
-- The LINE and ITEM counts, and every date, are complete over the whole
-- history; only the money is recent.
--
-- ═══ RETURNS ARE NETTED BY THE LINK, NOT BY DATE ═══════════════════════════
-- Unlike int_customer_item_purchases — which nets on posting date so history
-- stays immutable — this table attaches a credit to THE INVOICE IT CREDITS, via
-- sales_cr_memo_line.applies_to_invoice_no. That is the right choice here
-- because the question is "what did this invoice end up being worth", and a
-- credit raised against it belongs to it however long afterwards it posted.
--
-- THE CONSEQUENCE, and it is real: net_value is RETROACTIVELY MUTABLE. A credit
-- posted today changes an invoice dated three months ago. Anything that needs a
-- stable historical series should use int_customer_item_purchases instead, which
-- nets by posting date and never rewrites the past.
--
-- A standalone credit referencing no invoice is not counted here at all; it
-- still nets at customer level in int_customer_item_purchases.

with lines as (

    select
        invoice_no,
        customer_key,
        sales_code,
        posting_date,
        item_no,
        quantity,
        quantity_base,
        line_value,
        has_value
    from {{ ref('stg_nav__sales_invoice_lines') }}

),

-- Credits attached to the invoice they credit. Aggregated FIRST so the join
-- below cannot fan the invoice out — a credit memo can hold several lines
-- against one invoice.
credits as (

    select
        applies_to_invoice_no                                            as invoice_no,
        count(distinct cr_memo_no)                                       as cr_memo_count,
        sum(quantity)                                                    as returned_quantity,
        sum(line_value)                                                  as returned_value,
        max(posting_date)                                                as last_credit_date
    from {{ ref('stg_nav__sales_cr_memo_lines') }}
    where applies_to_invoice_no is not null
    group by applies_to_invoice_no

),

invoiced as (

    select
        l.invoice_no,

        -- SELL-TO from the lines. min() makes the pick deterministic where an
        -- invoice spans accounts; the count beside it says when that happened.
        min(l.customer_key)                                              as customer_key,
        count(distinct l.customer_key)                                   as sell_to_customer_count,
        min(l.sales_code)                                                as sales_code,
        count(distinct l.sales_code)                                     as sales_code_count,
        min(l.posting_date)                                              as posting_date,

        count(*)                                                         as line_count,
        count(distinct l.item_no)                                        as item_count,
        sum(l.quantity)                                                  as quantity_mixed_uom,
        sum(l.quantity_base)                                             as quantity_base,

        sum(l.line_value)                                                as invoice_value,
        sum(case when l.has_value then 1 else 0 end)                     as valued_line_count
    from lines as l
    group by l.invoice_no

)

select
    i.invoice_no,

    -- ── who and when ──────────────────────────────────────────────────────
    i.customer_key,
    c.customer_name,
    -- Above 1 means this invoice spans accounts and customer_key is one of
    -- several. Rare; published rather than hidden.
    i.sell_to_customer_count,
    i.sales_code,
    r.rep_name,
    i.sales_code_count,

    i.posting_date,
    h.order_date,
    -- days from the customer asking to the invoice posting. Negative would mean
    -- an order_date after posting, which is a data fault worth seeing.
    {{ dbt.datediff('h.order_date', 'i.posting_date', 'day') }}          as days_order_to_post,
    h.shipment_date,

    -- ── past terms. SPARSE — due_date only exists from 2026-09-20 ─────────
    -- has_due_date separates "not past terms" from "cannot tell", which a
    -- collections prompt must never confuse.
    h.due_date,
    coalesce(h.has_due_date, false)                                      as has_due_date,

    -- ── channel, on POSTED sales ──────────────────────────────────────────
    -- PDA / WEB / null. Null means keyed straight into NAV — a real case — OR
    -- that the invoice predates the export change. has_channel tells them apart.
    h.order_channel,
    coalesce(h.has_channel, false)                                       as has_channel,
    h.pda_order_no,
    h.m2_order_no,

    -- ── size ──────────────────────────────────────────────────────────────
    -- Complete over the whole history, unlike the value columns below. "16
    -- items, $2,000" is these two beside invoice_value.
    i.line_count,
    i.item_count,
    -- MIXED UOM: cases added to eaches. quantity_base is the comparable one,
    -- and it is null outside the conversion's coverage window.
    i.quantity_mixed_uom,
    i.quantity_base,

    -- ── value. PARTIAL, AND NEVER ZERO-FILLED ─────────────────────────────
    i.invoice_value,
    i.valued_line_count,
    (i.valued_line_count > 0)                                            as has_value,
    -- how much of the invoice carries money. Below 1 means invoice_value
    -- describes only part of what was sold on it.
    case when i.line_count > 0
         then round(i.valued_line_count * 1.0 / i.line_count, 3) end     as value_coverage,

    -- ── returns raised against THIS invoice ───────────────────────────────
    -- Netted by the credit's own link, so net_value is retroactively mutable —
    -- see the header before building a historical series on it.
    coalesce(cr.cr_memo_count, 0)                                        as cr_memo_count,
    cr.returned_quantity,
    cr.returned_value,
    cr.last_credit_date,
    (cr.invoice_no is not null)                                          as has_return,

    -- What the invoice ended up being worth. Null wherever invoice_value is
    -- null: an unvalued invoice minus a valued credit is not a number anyone
    -- should act on.
    case
        when i.invoice_value is not null
            then i.invoice_value - coalesce(cr.returned_value, 0)
    end                                                                  as net_value,
    -- The 2-3% alert the business asked for, per invoice. Null rather than 0
    -- where the value is missing on either side.
    case
        when i.invoice_value > 0 and cr.returned_value is not null
            then round(cr.returned_value / i.invoice_value, 4)
    end                                                                  as return_rate_value
from invoiced as i
left join {{ ref('stg_nav__sales_invoice_headers') }} as h on h.invoice_no = i.invoice_no
left join credits                                     as cr on cr.invoice_no = i.invoice_no
left join {{ ref('dim_customers') }}                  as c on c.customer_key = i.customer_key
left join {{ ref('dim_reps') }}                       as r on r.sales_code   = i.sales_code
