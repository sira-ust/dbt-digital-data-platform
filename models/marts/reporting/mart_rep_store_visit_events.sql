-- mart_rep_store_visit_events — the drill-down behind mart_rep_store_visits.
-- One row per rep work event, stamped with the rep-customer-day it belongs to.
--
--   select * from mart_rep_store_visit_events
--   where customer_day_key = '<a row from mart_rep_store_visits>'
--   order by event_seq
--
-- Grain is entity_id, so sum() is safe here and no day-level metric is repeated
-- onto event rows — that fan-out trap is why this is a separate table rather
-- than extra columns on the summary mart.
--
-- sales_code / customer_key / visit_date are denormalised on purpose so a day
-- can be filtered without joining back; they are constant per visit_key and
-- cannot fan out. Anything not here (geo, raw payload, l2-l4 codes) is one
-- join away on fct_events via entity_id, which is the PK on both.
--
-- increment_id is populated on submit rows ONLY, and is exact. It deliberately
-- is NOT back-filled onto the events preceding it: those events carry no order
-- number, so attributing them to the next submit would be a guess presented as
-- a fact. A stop with exactly one order (the common case) needs no such guess —
-- join to mart_rep_store_visits and check orders_submitted = 1.

with visit_events as (

    select * from {{ ref('int_rep_store_visits') }}

)

select
    customer_day_key,
    entity_id,

    sales_code,
    customer_key,
    visit_date,

    login_seq,
    event_seq,
    event_at_local,
    seconds_since_prev_event,

    device,
    description_code,
    function_name,
    feature_name,
    page_context,

    is_add,
    is_remove,
    is_qty_change,
    is_submit,
    increment_id
from visit_events
