{{ config(materialized='table') }}

with events as (

    select * from {{ ref('int_customer_tracking_enriched') }}
    where sku is not null

)

select
    customer_id,
    sku,
    max(customer_name)                                      as customer_name,
    max(item_no)                                            as item_no,
    max(categories_name)                                    as categories_name,

    -- interaction metrics
    count(*)                                                as total_interactions,
    count(distinct session_entity_id)                       as sessions_with_interaction,
    sum(qty) filter (where qty > 0)                         as total_qty_interacted,
    count(distinct cast(started_at as date))                as active_days_with_interaction,

    -- timing
    min(started_at)                                         as first_seen_at,
    max(started_at)                                         as last_seen_at

from events
group by
    customer_id,
    sku
