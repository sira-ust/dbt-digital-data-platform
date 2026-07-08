-- mart_customer_weekly — one row per customer x week: behaviour, feature
-- usage, self-service vs sales-assisted mode, friction signals, churn flag.
--
-- customer_key is the unified customer (decoded in int_events_decoded: sales
-- apps act FOR ust_customer_no, customer apps ARE username). Event-based
-- metrics (features, friction, adds/removes) come straight from
-- int_events_enriched so browsing outside any cycle still counts; cycle
-- counts come from fct_order_cycles; order counts from fct_orders (exact).
--
-- service_mode: share of the customer's behavioural events performed by
-- themselves vs a rep. >= 80% self -> self_service, <= 20% -> sales_assisted,
-- else mixed.
--
-- churn_signal: removes outnumber adds for var('churn_consecutive_weeks')
-- consecutive OBSERVED weeks (weeks with no activity don't reset the streak —
-- they simply don't count). Flag customers for UX follow-up, not a verdict.

with events as (

    select
        customer_key,
        cast({{ dbt.date_trunc('week', 'event_at_utc') }} as date)       as week_start,
        count(*)                                                         as event_count,
        sum(case when actor_type = 'customer' then 1 else 0 end)         as self_events,
        sum(case when actor_type = 'sales' then 1 else 0 end)            as rep_events,
        sum(case when is_add then 1 else 0 end)                          as add_count,
        sum(case when is_remove then 1 else 0 end)                       as remove_count,
        sum(case when is_qty_change then 1 else 0 end)                   as qty_change_count,
        sum(case when feature_name = 'search' then 1 else 0 end)         as search_count,
        sum(case when feature_name = 'filter' then 1 else 0 end)         as filter_count,
        sum(case when feature_name = 'icon_click' then 1 else 0 end)     as icon_click_count,
        sum(case when feature_name = 'catalog_view' then 1 else 0 end)   as catalog_view_count,
        sum(case when feature_name = 'item_detail' then 1 else 0 end)    as item_detail_count,
        sum(case when feature_name = 'oos_check' then 1 else 0 end)      as oos_check_count,
        sum(case when page_context = 'promo' then 1 else 0 end)          as promo_count,
        sum(case when page_context = 'backorder' then 1 else 0 end)      as backorder_count,
        sum(case when page_context = 'history' then 1 else 0 end)        as history_count,
        sum(case when page_context = 'suggest' then 1 else 0 end)        as suggest_count,
        -- friction families (L1): request review 05, sales review 06,
        -- restore order 07, delete order 08
        sum(case when l1_code = '05' then 1 else 0 end)                  as request_review_count,
        sum(case when l1_code = '06' then 1 else 0 end)                  as sales_review_count,
        sum(case when l1_code = '07' then 1 else 0 end)                  as restore_order_count,
        sum(case when l1_code = '08' then 1 else 0 end)                  as delete_order_count
    from {{ ref('int_events_enriched') }}
    where customer_key is not null
      and event_at_utc is not null
    group by 1, 2

),

cycles as (

    select
        customer_key,
        cast({{ dbt.date_trunc('week', 'started_at_utc') }} as date)     as week_start,
        count(*)                                                         as cycles,
        sum(case when is_submitted then 1 else 0 end)                    as cycles_submitted
    from {{ ref('fct_order_cycles') }}
    group by 1, 2

),

orders as (

    select
        customer_key,
        cast({{ dbt.date_trunc('week', 'submitted_at') }} as date)       as week_start,
        count(*)                                                         as orders_submitted,
        sum(grand_total)                                                 as order_value_total
    from {{ ref('fct_orders') }}
    where customer_key is not null
    group by 1, 2

),

combined as (

    select
        e.customer_key,
        e.week_start,
        e.event_count,
        e.self_events,
        e.rep_events,
        coalesce(c.cycles, 0)                                            as cycles,
        coalesce(c.cycles_submitted, 0)                                  as cycles_submitted,
        coalesce(o.orders_submitted, 0)                                  as orders_submitted,
        coalesce(o.order_value_total, 0)                                 as order_value_total,
        e.add_count,
        e.remove_count,
        e.qty_change_count,
        e.add_count - e.remove_count                                     as net_item_events,
        e.search_count,
        e.filter_count,
        e.icon_click_count,
        e.catalog_view_count,
        e.item_detail_count,
        e.oos_check_count,
        e.promo_count,
        e.backorder_count,
        e.history_count,
        e.suggest_count,
        e.request_review_count,
        e.sales_review_count,
        e.restore_order_count,
        e.delete_order_count,
        e.request_review_count + e.sales_review_count
            + e.restore_order_count + e.delete_order_count
            + e.oos_check_count                                          as friction_total,
        case
            when e.self_events >= 0.8 * e.event_count then 'self_service'
            when e.self_events <= 0.2 * e.event_count then 'sales_assisted'
            else 'mixed'
        end                                                              as service_mode,
        case when e.remove_count > e.add_count then 1 else 0 end         as remove_gt_add
    from events as e
    left join cycles as c
        on c.customer_key = e.customer_key and c.week_start = e.week_start
    left join orders as o
        on o.customer_key = e.customer_key and o.week_start = e.week_start

)

select
    *,
    remove_gt_add = 1                                                    as remove_gt_add_flag,
    -- streak over the trailing N observed weeks for this customer
    sum(remove_gt_add) over (
        partition by customer_key
        order by week_start
        rows between {{ var('churn_consecutive_weeks') - 1 }} preceding and current row
    ) = {{ var('churn_consecutive_weeks') }}                             as churn_signal
from combined
