{{ config(materialized='table') }}

-- NOT incremental by design: this is a lifetime aggregate with one row per page
-- and no date/partition grain. Every new event changes an existing page's totals,
-- so there's nothing to append — an incremental build would force a full recompute
-- anyway (or corrupt the running totals). Full-refresh table is the correct choice.

with events as (

    select * from {{ ref('stg_mysql__tracking_report_event') }}

),

classified as (

    select
        *,
        case
            when page like 'Search:%' then 'Search Results'
            else page
        end                                                         as page_name,
        case when page like 'Search:%' then true else false end     as is_search_page
    from events
    where page is not null

),

agg as (

    select
        page_name,
        is_search_page,
        count(*)                                                    as visit_count,
        count(distinct customer_id)                                 as distinct_customers,
        sum(duration_seconds)                                       as total_dwell_seconds,
        avg(duration_seconds)                                       as avg_dwell_seconds
    from classified
    group by 1, 2

)

select
    page_name,
    is_search_page,
    case
        when is_search_page then false
        when page_name in (
            'Home', 'Cart', 'Search', 'Categories', 'Product Detail',
            'My Orders', 'My Account', 'Backorder', 'New', 'Promo',
            'Recommended', 'More', 'Add to My List', 'Product List',
            'Place Your Order', 'Order Confirmation', 'My Order Detail',
            'Purchase History', 'Account Balance', 'Download Data',
            'U.S. Trading Company', 'Search Results'
        ) then false
        else true
    end                                                             as is_category_page,
    visit_count,
    distinct_customers,
    total_dwell_seconds,
    round(avg_dwell_seconds, 1)                                     as avg_dwell_seconds
from agg
order by visit_count desc
