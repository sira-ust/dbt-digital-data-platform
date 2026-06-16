-- fct_order_cycle — published order-cycle fact. One row per increment_id x
-- customer. Thin BI-facing view over int_order_cycle (cycle reconstruction
-- logic lives there). Consumed by mart_order_journey and BI drill-down.
-- Empty until the event-log extract contains Group 04/09 events.

select
    increment_id,
    customer_key,
    actor_type,
    source_code,
    app_name,
    sales_code,
    username,
    opened_at,
    submitted_at,
    is_submitted,
    days_to_close,
    create_events,
    submit_success_events,
    submit_fail_events
from {{ ref('int_order_cycle') }}
