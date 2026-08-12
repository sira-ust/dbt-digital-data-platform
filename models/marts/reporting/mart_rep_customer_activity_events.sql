-- mart_rep_customer_activity_events — the drill-down behind mart_rep_customer_activity.
-- One row per rep work event, stamped with the rep-customer-day it belongs to.
--
--   select * from mart_rep_customer_activity_events
--   where customer_day_key = '<a row from mart_rep_customer_activity>'
--   order by event_seq
--
-- Grain is entity_id, so sum() is safe here and no day-level metric is repeated
-- onto event rows — that fan-out trap is why this is a separate table rather
-- than extra columns on the summary mart.
--
-- sales_code / customer_key / activity_date are denormalised on purpose so a day
-- can be filtered without joining back; they are constant per customer_day_key
-- and cannot fan out. Anything not here (geo, raw payload, l2-l4 codes) is one
-- join away on fct_events via entity_id, which is the PK on both.
--
-- increment_id is populated on submit rows ONLY, and is exact. It deliberately
-- is NOT back-filled onto the events preceding it: those events carry no order
-- number, so attributing them to the next submit would be a guess presented as
-- a fact. A stop with exactly one order (the common case) needs no such guess —
-- join to mart_rep_customer_activity and check orders_submitted = 1.

with activity_events as (

    select * from {{ ref('int_rep_customer_activity') }}

)

select
    e.customer_day_key,
    e.entity_id,

    e.sales_code,
    e.customer_key,
    e.activity_date,

    e.login_seq,
    e.event_seq,
    e.event_at_local,
    e.seconds_since_prev_event,

    e.device,
    e.description_code,
    e.function_name,
    e.feature_name,
    e.page_context,

    e.is_add,
    e.is_remove,
    e.is_qty_change,
    e.is_submit,
    e.increment_id,
    -- PDA = the rep keyed it; WEB / APP = the customer placed it and it
    -- arrived for him to process. Null on non-submit rows.
    o.order_channel
from activity_events as e
left join {{ ref('fct_orders') }} as o
    on o.increment_id = e.increment_id
