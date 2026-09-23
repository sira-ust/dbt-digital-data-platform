-- stg_nav__sales_invoice_headers — POSTED sales invoices, one row per
-- document_no. Cast and trim only.
--
-- THE HEADER IS BILL-TO; THE LINES ARE SELL-TO, and for account-level work the
-- lines win. A chain billed centrally has one bill_to across many stores, so
-- attributing an invoice to bill_to_customer_no would credit the head office
-- for every branch's purchases. fct_invoices therefore takes its customer from
-- the LINES and uses this table only for dates, channel and shipment
-- attributes. bill_to_customer_no is carried so the billing relationship stays
-- visible, not because anything should key on it.
--
-- NO INVOICE TOTAL EXISTS HERE, and it is not an export omission. NAV computes
-- document totals as FlowFields — calculated on read, never stored — so there
-- is no column for ADF to select. An invoice's value is the sum of its lines,
-- full stop, and fct_invoices does exactly that.
--
-- DUE DATE AND THE CHANNEL KEYS ARE SPARSE. due_date, pda_order_no and
-- m2_order_no joined the export on 2026-09-20 and are populated on 119 of
-- 507,871 rows (measured 2026-09-23). Older invoices carry none of them and
-- never will, because the daily exports are deltas and the historical seed
-- holds the old column list. So "past terms" and the posted-sales channel split
-- both work for recent invoices only — see has_due_date and has_channel, which
-- exist so a consumer can tell "not past terms" from "cannot tell".

with source as (

    select * from {{ source('nav', 'sales_invoice_header') }}

)

select
    nullif(trim(cast(document_no as {{ dbt.type_string() }})), '')         as invoice_no,

    -- BILL-TO. Not the account that bought — see the header. Carried for the
    -- billing relationship only.
    nullif(trim(cast(bill_to_customer_no as {{ dbt.type_string() }})), '') as bill_to_customer_key,
    nullif(trim(cast(bill_to_name as {{ dbt.type_string() }})), '')        as bill_to_name,
    nullif(trim(cast(ship_to_name as {{ dbt.type_string() }})), '')        as ship_to_name,
    nullif(trim(cast(ship_to_city as {{ dbt.type_string() }})), '')        as ship_to_city,

    -- the rep credited with the DOCUMENT. The line carries its own, and the
    -- line's wins for per-rep work — a line can be credited differently from
    -- its header.
    nullif(trim(cast(salesperson_code as {{ dbt.type_string() }})), '')    as sales_code,

    -- ── dates. Cast to date: NAV posts to a day and the time is an export
    --    artefact. order_date is when the customer asked; posting_date is when
    --    it hit the books; the gap between them is the fulfilment lag.
    cast(order_date    as date)                                            as order_date,
    cast(posting_date  as date)                                            as posting_date,
    cast(shipment_date as date)                                            as shipment_date,
    cast(order_pick_date as date)                                          as order_pick_date,

    -- ── past terms. SPARSE — see the header ───────────────────────────────
    cast(due_date as date)                                                 as due_date,
    (due_date is not null)                                                 as has_due_date,

    -- ── channel on POSTED sales ───────────────────────────────────────────
    -- Only one is ever set: an order arrived through the PDA or through the
    -- website, not both. Both null means either it was keyed straight into NAV
    -- — a real and common case — OR the invoice predates the export change.
    -- has_channel separates those two, which matters because one is a fact
    -- about the order and the other is a fact about the pipeline.
    nullif(trim(cast(pda_order_no as {{ dbt.type_string() }})), '')        as pda_order_no,
    nullif(trim(cast(m2_order_no  as {{ dbt.type_string() }})), '')        as m2_order_no,
    (pda_order_no is not null or m2_order_no is not null)                  as has_channel,
    case
        when nullif(trim(cast(pda_order_no as {{ dbt.type_string() }})), '') is not null then 'PDA'
        when nullif(trim(cast(m2_order_no  as {{ dbt.type_string() }})), '') is not null then 'WEB'
    end                                                                    as order_channel,

    nullif(trim(cast(shipment_method_code as {{ dbt.type_string() }})), '') as shipment_method_code,
    nullif(trim(cast(customer_posting_group as {{ dbt.type_string() }})), '')
                                                                           as customer_posting_group,
    nullif(trim(cast(responsibility_center as {{ dbt.type_string() }})), '')
                                                                           as responsibility_center,
    cast(order_weight as {{ dbt.type_numeric() }})                         as order_weight,
    cast(order_cubage as {{ dbt.type_numeric() }})                         as order_cubage,
    cast(pallet_count_total as {{ dbt.type_int() }})                       as pallet_count_total,

    cast(loaddate as timestamp)                                            as loaded_at
from source
where document_no is not null
