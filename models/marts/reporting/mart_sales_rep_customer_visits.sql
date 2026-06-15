{{ config(materialized='table') }}

with events as (

    select * from {{ ref('int_user_activity_enriched') }}
    where customer_id is not null
      and username is not null

)

select
    username,
    sales_code,
    customer_id,

    -- visit metrics
    count(distinct session_entity_id)                               as total_sessions,
    count(*)                                                        as total_events,
    count(*) filter (where is_done = true)                          as completed_actions,
    count(distinct case when sku is not null then sku end)          as unique_skus_shown,

    -- order activity
    sum(case when qty is not null and qty > 0 then qty end)         as total_qty_ordered,

    -- timing
    min(cast(started_at as date))                                   as first_visit_date,
    max(cast(started_at as date))                                   as last_visit_date,
    count(distinct cast(started_at as date))                        as visit_days

from events
group by
    username,
    sales_code,
    customer_id
