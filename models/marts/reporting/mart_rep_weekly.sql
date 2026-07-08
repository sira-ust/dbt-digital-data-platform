-- mart_rep_weekly — one row per rep x week: workload + feature usage.
-- Answers "who's doing more or less work, and is team activity growing?"
--
-- Order counts/value come from fct_orders (EXACT). Everything "per cycle"
-- comes from fct_order_cycles (APPROXIMATE — time-heuristic cycles; label as
-- approximate in BI). Full outer join: a rep can have submitted orders in a
-- week with no reconstructed cycles, and vice versa.
--
-- pct_cycles_<feature> = share of the rep's cycles touching the feature;
-- avg_<feature>_per_cycle = average uses per cycle. Promo/backorder/history/
-- suggest are catalog sections (page_context); search/filter/icon_click/
-- catalog_view are actions (feature_name).

with cycles as (

    select
        sales_code,
        cast({{ dbt.date_trunc('week', 'started_at_utc') }} as date)     as week_start,
        count(*)                                                         as cycles_worked,
        sum(case when is_submitted then 1 else 0 end)                    as cycles_submitted,
        avg(add_count)                                                   as avg_adds_per_cycle,
        avg(remove_count)                                                as avg_removes_per_cycle,
        avg(net_item_events)                                             as avg_net_item_events,
        avg(active_minutes)                                              as avg_active_minutes,
        avg(days_to_close)                                               as avg_days_to_close,
        avg(case when search_count       > 0 then 1.0 else 0 end)        as pct_cycles_search,
        avg(case when filter_count       > 0 then 1.0 else 0 end)        as pct_cycles_filter,
        avg(case when icon_click_count   > 0 then 1.0 else 0 end)        as pct_cycles_icon_click,
        avg(case when catalog_view_count > 0 then 1.0 else 0 end)        as pct_cycles_catalog_view,
        avg(case when promo_count        > 0 then 1.0 else 0 end)        as pct_cycles_promo,
        avg(case when backorder_count    > 0 then 1.0 else 0 end)        as pct_cycles_backorder,
        avg(case when history_count      > 0 then 1.0 else 0 end)        as pct_cycles_history,
        avg(case when suggest_count      > 0 then 1.0 else 0 end)        as pct_cycles_suggest,
        avg(search_count)                                                as avg_search_per_cycle,
        avg(filter_count)                                                as avg_filter_per_cycle,
        avg(icon_click_count)                                            as avg_icon_click_per_cycle,
        avg(catalog_view_count)                                          as avg_catalog_view_per_cycle,
        avg(promo_count)                                                 as avg_promo_per_cycle,
        avg(backorder_count)                                             as avg_backorder_per_cycle,
        avg(history_count)                                               as avg_history_per_cycle,
        avg(suggest_count)                                               as avg_suggest_per_cycle
    from {{ ref('fct_order_cycles') }}
    where is_sales_assisted and sales_code is not null
    group by 1, 2

),

orders as (

    select
        sales_code,
        cast({{ dbt.date_trunc('week', 'submitted_at') }} as date)       as week_start,
        count(*)                                                         as orders_submitted,
        sum(grand_total)                                                 as order_value_total
    from {{ ref('fct_orders') }}
    where sales_code is not null
    group by 1, 2

),

-- one display name per territory code (guard against join fan-out)
reps as (

    select
        salesperson_code,
        max(first_name || ' ' || last_name)                              as rep_name
    from {{ ref('stg_mysql__admin_users') }}
    where salesperson_code is not null
    group by salesperson_code

)

select
    coalesce(c.sales_code, o.sales_code)                                 as sales_code,
    r.rep_name,
    coalesce(c.week_start, o.week_start)                                 as week_start,
    coalesce(o.orders_submitted, 0)                                      as orders_submitted,
    coalesce(o.order_value_total, 0)                                     as order_value_total,
    coalesce(c.cycles_worked, 0)                                         as cycles_worked,
    coalesce(c.cycles_submitted, 0)                                      as cycles_submitted,
    c.avg_adds_per_cycle,
    c.avg_removes_per_cycle,
    c.avg_net_item_events,
    c.avg_active_minutes,
    c.avg_days_to_close,
    c.pct_cycles_search,
    c.pct_cycles_filter,
    c.pct_cycles_icon_click,
    c.pct_cycles_catalog_view,
    c.pct_cycles_promo,
    c.pct_cycles_backorder,
    c.pct_cycles_history,
    c.pct_cycles_suggest,
    c.avg_search_per_cycle,
    c.avg_filter_per_cycle,
    c.avg_icon_click_per_cycle,
    c.avg_catalog_view_per_cycle,
    c.avg_promo_per_cycle,
    c.avg_backorder_per_cycle,
    c.avg_history_per_cycle,
    c.avg_suggest_per_cycle
from cycles as c
full outer join orders as o
    on o.sales_code = c.sales_code and o.week_start = c.week_start
left join reps as r
    on r.salesperson_code = coalesce(c.sales_code, o.sales_code)
