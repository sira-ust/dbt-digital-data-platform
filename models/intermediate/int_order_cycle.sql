-- int_order_cycle — order-cycle reconstruction at cycle grain.
-- One row per matched open → close pair (username × increment_id).
-- Only successful submissions (l3=01) are used as close events — a failed
-- send does not constitute a completed cycle.
--
-- Create Order events (l1=09) carry a device-side local_id in the response;
-- Send Order success events (l1=04, l3=01) carry the server-assigned
-- increment_id in the KV payload. The two ID spaces never overlap so direct
-- ID joins are impossible. Cycles are matched via temporal LEFT JOIN: for each
-- close, find the closest Create Order event that precedes it for the same
-- username + customer, then keep only 1:1 pairs via dual ROW_NUMBER.
--
-- Excludes 09060000 (BLE use-existing) and 09070000 (BLE merge).

with events as (

    select * from {{ ref('int_events_enriched') }}

),

create_events as (

    select
        username,
        sales_code,
        source_code,
        app_version,
        event_at_utc,
        {{ response_part('response', 1) }}                             as order_customer_no,
        {{ response_part('response', 2) }}                             as local_id
    from events
    where l1_category_name = 'Create Order'
      and description_code not in ('09060000', '09070000')
      and actor_type = 'sales'

),

send_events as (

    select
        username,
        customer_key,
        event_at_utc,
        {{ parse_kv_response('response', 'increment_id') }}            as increment_id
    from events
    where l1_category_name = 'Send Order'
      and l3_code = '01'

),

cycle_open as (

    select
        username,
        order_customer_no,
        local_id,
        sales_code,
        source_code,
        app_version,
        min(event_at_utc)                                              as opened_at
    from create_events
    where local_id is not null
    group by
        username, order_customer_no, local_id,
        sales_code, source_code, app_version

),

cycle_close as (

    select
        username,
        customer_key,
        increment_id,
        min(event_at_utc)                                              as submitted_at
    from send_events
    where increment_id is not null
    group by username, customer_key, increment_id

),

matched as (

    select
        c.username,
        c.customer_key                                                 as order_customer_no,
        c.increment_id,
        c.submitted_at,
        o.local_id,
        o.opened_at,
        o.sales_code,
        o.source_code,
        o.app_version,
        row_number() over (
            partition by c.username, c.customer_key, c.increment_id
            order by o.opened_at desc
        )                                                              as open_rank_for_close,
        row_number() over (
            partition by o.username, o.order_customer_no, o.local_id
            order by c.submitted_at asc
        )                                                              as close_rank_for_open
    from cycle_close c
    left join cycle_open o
        on  o.username          = c.username
        and o.order_customer_no = c.customer_key
        and o.opened_at         < c.submitted_at

)

select
    username,
    order_customer_no,
    local_id,
    increment_id,
    sales_code,
    source_code,
    app_version,
    opened_at,
    submitted_at,
    {{ dbt.datediff('opened_at', 'submitted_at', 'day') }}             as days_to_close
from matched
where open_rank_for_close = 1
  and close_rank_for_open = 1
