-- DQ audit of demand-payload skus that match no WMS item. Two failure
-- modes end up here:
--   1. well-formed numeric skus absent from prtmst (discontinued items,
--      items of an unmirrored warehouse, or genuine master-data gaps)
--   2. nothing — malformed payloads are already dropped by the shape
--      filter in int_item_demand_daily and never reach this view
-- One row per unmatched sku, most demand first. Keeps the ~11% payload
-- loss measured 2026-07-13 visible instead of silently shrinking the
-- demand numbers in mart_item_demand_supply.

with demand as (

    select
        sku,
        min(activity_date)                                              as first_seen,
        max(activity_date)                                              as last_seen,
        sum(item_detail_views + image_enlarge_views)                    as item_views,
        sum(cart_adds)                                                  as cart_adds,
        sum(cart_add_qty)                                               as cart_add_qty
    from {{ ref('int_item_demand_daily') }}
    group by 1

),

items as (

    select distinct prtnum from {{ ref('int_jdawms_items') }}

)

select
    d.sku,
    d.first_seen,
    d.last_seen,
    d.item_views,
    d.cart_adds,
    d.cart_add_qty,
    d.item_views + d.cart_adds                                          as demand_events
from demand as d
left join items as i
    on i.prtnum = d.sku
where i.prtnum is null
order by demand_events desc
