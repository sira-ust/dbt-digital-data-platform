-- mart_sales_agent_performance — daily sales-agent scorecard combining
-- order outcomes (L1 = 04) with app-usage behaviour on the sales apps
-- (PDA-A, CatalogFS-I, CatalogFS-A).
--
-- Grain: activity_date (UTC, server clock) x username (agent login) x
-- source_code — so PDA usage and CatalogFS usage land on separate rows and
-- can be compared per app or rolled up per agent.
--
-- Identity rules (per API doc): on sales apps `username` is the salesperson
-- login and `ust_customer_no` (-> customer_key) is the customer they are
-- acting for. Aggregate table, rebuilt each run — at ~600k events/month the
-- daily-agent grain stays small even over years.

{{ config(materialized='table') }}

with sales_events as (

    select * from {{ ref('int_events_enriched') }}
    where actor_type = 'sales'
      and username is not null

),

orders as (

    select * from {{ ref('int_orders_submitted') }}
    where actor_type = 'sales'
      and username is not null

),

usage_daily as (

    select
        cast(created_at_utc as date) as activity_date,
        username,
        source_code,

        max(sales_code) as sales_code,
        max(app_name) as app_name,
        max(app_platform) as app_platform,

        -- overall activity
        count(*) as total_events,
        min(created_at_utc) as first_event_utc,
        max(created_at_utc) as last_event_utc,
        count(distinct device_name) as distinct_devices,
        count(distinct customer_key) as distinct_customers_touched,

        -- logins (0203xx)
        sum(case when l1_code = '02' and l2_code = '03' and is_success then 1 else 0 end)
            as logins_succeeded,
        sum(case when l1_code = '02' and l2_code = '03' and is_failure then 1 else 0 end)
            as logins_failed,

        -- data downloads / syncs (03xx)
        sum(case when l1_code = '03' and is_success then 1 else 0 end)
            as downloads_succeeded,
        sum(case when l1_code = '03' and is_failure then 1 else 0 end)
            as downloads_failed,

        -- catalog & product engagement
        sum(case when description_code = '19010000' then 1 else 0 end)
            as catalog_views,
        sum(case when l1_code in ('10', '14', '15', '18') then 1 else 0 end)
            as item_interactions

    from sales_events
    group by cast(created_at_utc as date), username, source_code

),

orders_daily as (

    select
        cast(created_at_utc as date) as activity_date,
        username,
        source_code,

        count(*) as orders_submitted,
        sum(case when is_success then 1 else 0 end) as orders_succeeded,
        sum(case when is_failure then 1 else 0 end) as orders_failed,
        count(distinct case when is_success then customer_key end)
            as customers_ordered_for,

        -- value metrics from the positional payload (successes carry it)
        sum(case when is_success then grand_total end) as order_value_total,
        avg(case when is_success then grand_total end) as order_value_avg,
        sum(case when is_success then total_item_count end) as items_ordered_total,
        avg(case when is_success then duration_s end) as order_duration_avg_s

    from orders
    group by cast(created_at_utc as date), username, source_code

)

select
    u.activity_date,
    u.username,
    u.source_code,
    u.sales_code,
    u.app_name,
    u.app_platform,

    -- ── sales performance ──────────────────────────────────────────────
    coalesce(o.orders_submitted, 0) as orders_submitted,
    coalesce(o.orders_succeeded, 0) as orders_succeeded,
    coalesce(o.orders_failed, 0) as orders_failed,
    case when coalesce(o.orders_submitted, 0) > 0
         then cast(o.orders_succeeded as double) / o.orders_submitted
    end as order_success_rate,
    coalesce(o.customers_ordered_for, 0) as customers_ordered_for,
    o.order_value_total,
    o.order_value_avg,
    o.items_ordered_total,
    o.order_duration_avg_s,

    -- ── app usage ──────────────────────────────────────────────────────
    u.total_events,
    u.first_event_utc,
    u.last_event_utc,
    u.distinct_devices,
    u.distinct_customers_touched,
    u.logins_succeeded,
    u.logins_failed,
    u.downloads_succeeded,
    u.downloads_failed,
    case when u.downloads_succeeded + u.downloads_failed > 0
         then cast(u.downloads_failed as double)
              / (u.downloads_succeeded + u.downloads_failed)
    end as download_failure_rate,
    u.catalog_views,
    u.item_interactions

from usage_daily u
left join orders_daily o
    on  u.activity_date = o.activity_date
    and u.username = o.username
    and u.source_code = o.source_code
order by u.activity_date, u.username, u.source_code
