-- int_order_cycle — keystone order grain for Pages 1 & 3.
-- One row per increment_id x customer, reconstructed EXACTLY from the order
-- events that carry increment_id (no add-event linkage needed):
--   open  = Create Order (09010000), payload = increment_id
--   close = any Group 04 submit success (04010100/020100/030100/040100/050100),
--           payload position 1 = increment_id
-- days_to_close = submitted_at - opened_at. A cycle with an open but no submit
-- is pending. Cart-edit counts per cycle (add/remove) are intentionally NOT
-- here — add/remove events carry no increment_id, so per-cycle edit metrics
-- need a heuristic and remain deferred (see DEFERRED-MODELS.md). Cart activity
-- at customer grain lives in mart_cart_behaviour.
--
-- On the current extract this is empty (no Group 04/09 events); it populates
-- automatically once such events arrive.

with order_events as (

    select
        customer_key,
        actor_type,
        source_code,
        app_name,
        sales_code,
        username,
        description_code,
        l1_code,
        is_success,
        is_failure,
        event_at_utc,
        -- increment_id sits at payload position 1 for both create and submit
        {{ response_part('response', 1) }}                             as increment_id
    from {{ ref('int_events_enriched') }}
    where l1_code = '04'
       or description_code = '09010000'

),

filtered as (

    select * from order_events
    where increment_id is not null
      and increment_id <> ''

),

aggregated as (

    select
        increment_id,
        customer_key,
        max(actor_type)                                                as actor_type,
        max(source_code)                                               as source_code,
        max(app_name)                                                  as app_name,
        max(sales_code)                                                as sales_code,
        max(username)                                                  as username,

        min(case when description_code = '09010000' then event_at_utc end) as opened_at,
        min(case when l1_code = '04' and is_success then event_at_utc end) as submitted_at,
        max(case when l1_code = '04' and is_success then 1 else 0 end) = 1  as is_submitted,

        count(*) filter (where description_code = '09010000')          as create_events,
        count(*) filter (where l1_code = '04' and is_success)          as submit_success_events,
        count(*) filter (where l1_code = '04' and is_failure)          as submit_fail_events
    from filtered
    group by increment_id, customer_key

)

select
    *,
    {{ dbt.datediff('opened_at', 'submitted_at', 'day') }}            as days_to_close
from aggregated
