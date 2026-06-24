{{ config(materialized='table') }}

-- mart_order_journey — per-cycle behaviour at order-cycle grain.
-- One row per matched open→close cycle (from int_order_cycle). All events
-- that fall within the cycle window are joined from fct_events and aggregated
-- into cart, navigation, feature-flag, and submit-quality metrics.
-- behavior_segment requires add_count (High Editor) so is fully computed here.

with cycles as (

    select * from {{ ref('int_order_cycle') }}

),

cycle_events as (

    select
        e.l1_category_name,
        e.l2_code,
        e.l3_code,
        o.username,
        o.order_customer_no,
        o.local_id,
        o.increment_id,
        o.sales_code,
        o.source_code,
        o.app_version,
        o.opened_at,
        o.submitted_at,
        o.days_to_close
    from {{ ref('fct_events') }} e
    inner join cycles o
        on  e.username     = o.username
        and e.event_at_utc between o.opened_at
            and coalesce(o.submitted_at, {{ dbt.current_timestamp() }})
    where e.actor_type = 'sales'

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
    days_to_close,

    case
        when days_to_close = 0              then 'same-day'
        when days_to_close between 1 and 3  then '1-3d'
        when days_to_close between 4 and 7  then '4-7d'
        when days_to_close between 8 and 14 then '8-14d'
        else '14d+'
    end                                                                as cycle_bucket,

    -- ── cart (Order Operations) ────────────────────────────────────────
    count(case when l1_category_name = 'Order Operations' and l2_code = '05' then 1 end) as add_count,
    count(case when l1_category_name = 'Order Operations' and l2_code = '04' then 1 end) as remove_count,
    count(case when l1_category_name = 'Order Operations' and l2_code = '13' then 1 end) as oos_check_count,
    cast(count(case when l1_category_name = 'Order Operations' and l2_code = '04' then 1 end) as double)
        / nullif(count(case when l1_category_name = 'Order Operations' and l2_code = '05' then 1 end), 0)
                                                                       as churn_ratio,

    -- ── icon clicks (Activity) ─────────────────────────────────────────
    count(case when l1_category_name = 'Activity (Customer Interactions)' and l2_code = '02' then 1 end) as click_backorder_count,
    count(case when l1_category_name = 'Activity (Customer Interactions)' and l2_code = '03' then 1 end) as click_history_count,
    count(case when l1_category_name = 'Activity (Customer Interactions)' and l2_code = '04' then 1 end) as click_suggest_count,
    count(case when l1_category_name = 'Activity (Customer Interactions)' and l2_code = '05' then 1 end) as click_new_count,
    count(case when l1_category_name = 'Activity (Customer Interactions)' and l2_code = '06' then 1 end) as click_promo_count,
    count(case when l1_category_name = 'Activity (Customer Interactions)' and l2_code = '07' then 1 end) as click_new_promo_count,

    -- ── navigation ─────────────────────────────────────────────────────
    count(case when l1_category_name = 'Filtering & Sorting' then 1 end)                   as filter_events,
    count(case when l1_category_name = 'Search' then 1 end)                                as search_events,
    count(case when l1_category_name = 'Activity (Customer Interactions)' then 1 end)      as icon_clicks,
    count(case when l1_category_name = 'Catalog View Analytics' then 1 end)                as catalog_views,

    -- ── feature flags (did they use it in this cycle?) ─────────────────
    max(case when l1_category_name = 'Filtering & Sorting' then 1 else 0 end)              as used_filter,
    max(case when l1_category_name = 'Search' then 1 else 0 end)                           as used_search,
    max(case when l1_category_name = 'Activity (Customer Interactions)' then 1 else 0 end) as used_icons,
    max(case when l1_category_name = 'Catalog View Analytics' then 1 else 0 end)           as used_catalog_view,
    max(case when l1_category_name = 'Activity (Customer Interactions)' and l2_code = '02' then 1 else 0 end) as used_backorder,
    max(case when l1_category_name = 'Activity (Customer Interactions)' and l2_code = '03' then 1 else 0 end) as used_history,
    max(case when l1_category_name = 'Activity (Customer Interactions)' and l2_code = '04' then 1 else 0 end) as used_suggest,
    max(case when l1_category_name = 'Activity (Customer Interactions)' and l2_code = '05' then 1 else 0 end) as used_new,
    max(case when l1_category_name = 'Activity (Customer Interactions)' and l2_code = '06' then 1 else 0 end) as used_promo,
    max(case when l1_category_name = 'Activity (Customer Interactions)' and l2_code = '07' then 1 else 0 end) as used_new_promo,
    max(case when l1_category_name = 'Activity (Customer Interactions)' and l2_code = '08' then 1 else 0 end) as used_all_product,
    max(case when l1_category_name = 'Activity (Customer Interactions)' and l2_code = '09' then 1 else 0 end) as used_categories,

    -- ── submit quality ─────────────────────────────────────────────────
    max(case when l1_category_name = 'Send Order' then 1 else 0 end)                       as had_submit_attempt,
    count(case when l1_category_name = 'Send Order' and l3_code = '02' then 1 end)         as submit_fail_count,

    -- ── behavior segment ───────────────────────────────────────────────
    case
        when cast(count(case when l1_category_name = 'Order Operations' and l2_code = '04' then 1 end) as double)
           / nullif(count(case when l1_category_name = 'Order Operations' and l2_code = '05' then 1 end), 0) >= 0.3
            then 'High Editor'
        when cast(count(case when l1_category_name = 'Order Operations' and l2_code = '04' then 1 end) as double)
           / nullif(count(case when l1_category_name = 'Order Operations' and l2_code = '05' then 1 end), 0) < 0.1
          and days_to_close <= 1
            then 'Decisive'
        when days_to_close >= 4 then 'Planner'
        else 'Slow Sender'
    end                                                                as behavior_segment

from cycle_events
group by
    username, order_customer_no, local_id, increment_id, sales_code,
    source_code, app_version, opened_at, submitted_at, days_to_close
