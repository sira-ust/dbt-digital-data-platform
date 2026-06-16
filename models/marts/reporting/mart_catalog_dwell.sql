{{ config(materialized='table') }}

-- mart_catalog_dwell — Page 2 category dwell heatmap.
-- Grain: category. Aggregates Catalog View analytics (int_catalog_dwell) to
-- show, per category, how many view events and customers, total pages viewed,
-- and average / total time-on-page. Powers the "category vs avg dwell time"
-- heatmap. Unknown category ids (not in seed_categories) roll up to (unknown).

with dwell as (

    select * from {{ ref('int_catalog_dwell') }}

)

select
    coalesce(category_id, '(unknown)')                                 as category_id,
    max(category_name)                                                 as category_name,
    count(*)                                                           as view_events,
    count(distinct customer_key)                                       as distinct_customers,
    sum(pages_viewed)                                                  as total_pages_viewed,
    sum(dwell_seconds)                                                 as total_dwell_seconds,
    avg(dwell_seconds)                                                 as avg_dwell_seconds
from dwell
group by coalesce(category_id, '(unknown)')
