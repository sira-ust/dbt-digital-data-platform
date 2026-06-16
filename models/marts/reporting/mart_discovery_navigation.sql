{{ config(materialized='table') }}

-- mart_discovery_navigation — Page 2 feature click->add funnel.
-- Grain: feature (Recommend / Promo / New / Backorder). For each feature:
-- how many icon clicks and page adds happened, how many customers clicked vs
-- added, and the behaviour-level click->add conversion (of customers who
-- clicked the feature icon, how many also added from that feature's page).
-- Companion mart_catalog_dwell covers the category dwell heatmap.

with funnel as (

    select * from {{ ref('int_feature_funnel') }}

)

select
    feature,
    sum(click_events)                                                  as click_events,
    sum(add_events)                                                    as add_events,
    count(distinct case when click_events > 0 then customer_key end)   as customers_clicked,
    count(distinct case when add_events > 0 then customer_key end)     as customers_added,
    count(distinct case when click_events > 0 and add_events > 0
                        then customer_key end)                         as customers_clicked_and_added,
    cast(
        count(distinct case when click_events > 0 and add_events > 0 then customer_key end)
        as double
    ) / nullif(count(distinct case when click_events > 0 then customer_key end), 0)
                                                                       as click_to_add_rate
from funnel
group by feature
