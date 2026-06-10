-- Order submission events (L1 = 04, Send Order family).
-- Payload: positional CSV order metadata —
--   increment_id, order_source, grand_total, duration, subtotal,
--   total_item_count, ust_customer_no
--   e.g. M000072209,CAT,1250.00,45,1100.00,8,ASI325

with events as (

    select * from {{ ref('int_events_enriched') }}
    where l1_code = '04'

)

select
    entity_id,
    description_code,
    function_name,
    is_success,
    is_failure,
    source_code,
    app_name,
    app_platform,
    actor_type,
    username,
    customer_key,
    sales_code,
    created_at_utc,
    event_at_utc,

    -- positional payload
    {{ response_part('response', 1) }} as increment_id,
    {{ response_part('response', 2) }} as order_source,
    try_cast({{ response_part('response', 3) }} as decimal(18, 2)) as grand_total,
    try_cast({{ response_part('response', 4) }} as integer) as duration_s,
    try_cast({{ response_part('response', 5) }} as decimal(18, 2)) as subtotal,
    try_cast({{ response_part('response', 6) }} as integer) as total_item_count,
    {{ response_part('response', 7) }} as payload_ust_customer_no

from events
