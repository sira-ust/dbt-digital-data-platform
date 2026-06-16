{{ config(materialized='table') }}

-- mart_cart_behaviour — Page 3 cart behaviour at CUSTOMER grain.
-- Without order linkage (add/remove events carry no increment_id, and the
-- current extract has no submit events), cart activity is summarised per
-- customer rather than per order cycle. Churn ratio = remove_events /
-- add_events. Order-cycle framing (churn per cycle, same-day vs multi-day
-- timeline, conversion) is deferred until order events land — see
-- DEFERRED-MODELS.md (mart_order_journey / int_order_cycle).
--
-- Cart edits live in Group 10: L2=05 add_item_*, L2=04 remove_item_*,
-- L2=15 change_qty_item_*. Payload position 1 is the sku for all three.

with events as (

    select * from {{ ref('int_events_enriched') }}
    where l1_code = '10'
      and l2_code in ('04', '05', '15')

),

classified as (

    select
        customer_key,
        actor_type,
        cast(event_at_utc as date)                                     as event_date,
        {{ response_part('response', 1) }}                             as sku,
        case
            when l2_code = '05' then 'add'
            when l2_code = '04' then 'remove'
            when l2_code = '15' then 'qty_change'
        end                                                            as cart_action
    from events

)

select
    customer_key,
    max(actor_type)                                                    as actor_type,

    count(*) filter (where cart_action = 'add')                        as add_events,
    count(*) filter (where cart_action = 'remove')                     as remove_events,
    count(*) filter (where cart_action = 'qty_change')                 as qty_change_events,
    count(distinct case when cart_action = 'add' and sku is not null
                        then sku end)                                  as distinct_skus_added,

    -- cart churn: how heavily customers revise before they are done
    cast(count(*) filter (where cart_action = 'remove') as double)
        / nullif(count(*) filter (where cart_action = 'add'), 0)       as churn_ratio,

    count(distinct event_date)                                         as active_cart_days,
    min(event_date)                                                    as first_cart_date,
    max(event_date)                                                    as last_cart_date
from classified
where customer_key is not null
group by customer_key
