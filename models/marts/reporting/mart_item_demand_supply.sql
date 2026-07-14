-- mart_item_demand_supply — app demand vs CABOT warehouse supply, one row
-- per item x ISO week. Answers three questions:
--   1. missed opportunity   high views/cart-adds while shippable stock was
--                           zero or dry most of the week
--   2. promote candidate    stock on hand but little or no app interest
--   3. restock risk         interest trending up while inventory is flat
--
-- Demand = interest at browse time (views, cart adds), NOT fulfilled sales:
-- there is no order-level link to the WMS yet (ord mirror pending). The
-- demand x stock comparison is same-day: "when the customer looked, could
-- CABOT have shipped it?". Supply covers warehouse CABOT ONLY — an item
-- 'out of stock' here may ship from an unmirrored site. Demand history
-- starts 2026-01-22 (event log go-live).
--
-- Spine: full outer join of demand and supply weeks, then inner join to
-- the item master — junk payload skus fall out here (kept visible in
-- dq_unmatched_demand_skus); real items with zero demand stay because
-- inv_snap covers every item every day.
--
-- Trend windows use the item's prior 4 observed weeks. Thresholds are vars
-- (dbt_project.yml, demand_supply_*) so they can be tuned without a code
-- change. Full rebuild each run: ~5.7k items x weeks is small, and the
-- windows need history anyway.

with demand_daily as (

    select * from {{ ref('int_item_demand_daily') }}

),

inventory_daily as (

    -- collapse prt_client_id / wh_id (single-valued in practice) so the
    -- day grain is item x date, matching the demand side
    select
        prtnum,
        snapshot_date,
        sum(shippable_qty)                                              as shippable_qty,
        sum(on_hand_qty)                                                as on_hand_qty,
        sum(planned_qty)                                                as planned_qty,
        sum(pnd_rcvqty)                                                 as pnd_rcvqty
    from {{ ref('int_jdawms_inventory_daily') }}
    group by 1, 2

),

demand_weekly as (

    select
        sku,
        cast({{ dbt.date_trunc('week', 'activity_date') }} as date)     as week_start,
        sum(item_detail_views + image_enlarge_views)                     as item_views,
        sum(cart_adds)                                                   as cart_adds,
        sum(cart_removes)                                                as cart_removes,
        sum(cart_add_qty)                                                as cart_add_qty,
        max(distinct_customers)                                          as peak_daily_customers,
        count(distinct activity_date)                                    as active_days
    from demand_daily
    group by 1, 2

),

supply_weekly as (

    select
        prtnum,
        cast({{ dbt.date_trunc('week', 'snapshot_date') }} as date)      as week_start,
        avg(shippable_qty)                                               as avg_shippable_qty,
        min(shippable_qty)                                               as min_shippable_qty,
        avg(on_hand_qty)                                                 as avg_on_hand_qty,
        sum(case when shippable_qty <= 0 then 1 else 0 end)              as days_out_of_stock,
        count(*)                                                         as snapshot_days,
        max(planned_qty + pnd_rcvqty)                                    as inbound_qty_peak
    from inventory_daily
    group by 1, 2

),

-- end-of-week stock: the last snapshot within each item-week
supply_eow as (

    select
        prtnum,
        week_start,
        shippable_qty                                                    as shippable_eow
    from (
        select
            prtnum,
            cast({{ dbt.date_trunc('week', 'snapshot_date') }} as date)  as week_start,
            shippable_qty,
            row_number() over (
                partition by prtnum,
                             cast({{ dbt.date_trunc('week', 'snapshot_date') }} as date)
                order by snapshot_date desc
            )                                                            as _rn
        from inventory_daily
    )
    where _rn = 1

),

-- same-day overlap: demand that landed on a zero-shippable snapshot day
oos_overlap as (

    select
        d.sku,
        cast({{ dbt.date_trunc('week', 'd.activity_date') }} as date)    as week_start,
        sum(case when i.shippable_qty <= 0
                 then d.cart_adds else 0 end)                            as cart_adds_while_oos,
        sum(case when i.shippable_qty <= 0
                 then d.item_detail_views + d.image_enlarge_views
                 else 0 end)                                             as views_while_oos
    from demand_daily as d
    inner join inventory_daily as i
        on i.prtnum = d.sku
       and i.snapshot_date = d.activity_date
    group by 1, 2

),

combined as (

    select
        coalesce(d.sku, s.prtnum)                                        as prtnum,
        coalesce(d.week_start, s.week_start)                             as week_start,
        coalesce(d.item_views, 0)                                        as item_views,
        coalesce(d.cart_adds, 0)                                         as cart_adds,
        coalesce(d.cart_removes, 0)                                      as cart_removes,
        coalesce(d.cart_add_qty, 0)                                      as cart_add_qty,
        coalesce(d.peak_daily_customers, 0)                              as peak_daily_customers,
        coalesce(d.active_days, 0)                                       as demand_active_days,
        s.avg_shippable_qty,
        s.min_shippable_qty,
        s.avg_on_hand_qty,
        coalesce(s.days_out_of_stock, 0)                                 as days_out_of_stock,
        coalesce(s.snapshot_days, 0)                                     as snapshot_days,
        s.inbound_qty_peak,
        e.shippable_eow,
        coalesce(o.cart_adds_while_oos, 0)                               as cart_adds_while_oos,
        coalesce(o.views_while_oos, 0)                                   as views_while_oos
    from demand_weekly as d
    full outer join supply_weekly as s
        on s.prtnum = d.sku and s.week_start = d.week_start
    left join supply_eow as e
        on e.prtnum = coalesce(d.sku, s.prtnum)
       and e.week_start = coalesce(d.week_start, s.week_start)
    left join oos_overlap as o
        on o.sku = coalesce(d.sku, s.prtnum)
       and o.week_start = coalesce(d.week_start, s.week_start)

),

-- the event log goes live 2026-01-22 but inv_snap history starts 2025-10.
-- The mart is demand-driven: weeks before the first demand week are
-- filtered out BEFORE the trend windows — those weeks carry coalesced
-- zeros for demand (no data, not zero interest), and letting them into
-- the windows would dilute the first weeks' baselines toward 0. The
-- first demand weeks therefore have null / partial baselines (honest:
-- no history yet) instead of fabricated ones. Supply-only history stays
-- available in int_jdawms_inventory_daily.
demand_start as (

    select min(week_start) as first_demand_week from demand_weekly

),

windowed as (

    select
        c.*,
        c.item_views + c.cart_adds                                       as demand_events,
        avg(c.item_views) over (
            partition by c.prtnum order by c.week_start
            rows between 4 preceding and 1 preceding
        )                                                                as views_prior_4wk_avg,
        avg(c.shippable_eow) over (
            partition by c.prtnum order by c.week_start
            rows between 4 preceding and 1 preceding
        )                                                                as shippable_eow_prior_4wk_avg
    from combined as c
    cross join demand_start as ds
    where c.week_start >= ds.first_demand_week

)

select
    w.prtnum,
    w.week_start,
    i.item_name,
    i.item_family,
    i.abc_class,
    i.abc_class_description,
    i.velocity_zone,
    w.item_views,
    w.cart_adds,
    w.cart_removes,
    w.cart_add_qty,
    w.peak_daily_customers,
    w.demand_active_days,
    w.demand_events,
    w.views_prior_4wk_avg,
    w.avg_shippable_qty,
    w.min_shippable_qty,
    w.avg_on_hand_qty,
    w.shippable_eow,
    w.shippable_eow_prior_4wk_avg,
    w.days_out_of_stock,
    w.snapshot_days,
    w.inbound_qty_peak,
    w.cart_adds_while_oos,
    w.views_while_oos,

    -- interest is trending when this week's views beat the prior-4-week
    -- average by the configured ratio (with a floor so 1 -> 2 views doesn't
    -- count as a trend)
    (
        w.views_prior_4wk_avg >= {{ var('demand_supply_trend_min_base_views') }}
        and w.item_views >= {{ var('demand_supply_trend_ratio') }} * w.views_prior_4wk_avg
    )                                                                    as is_trending_interest,

    case
        -- demand hit a dry shelf: enough interest AND (stock was out most
        -- of the observed week OR carts were added on zero-stock days)
        when (w.item_views + w.cart_adds) >= {{ var('demand_supply_min_demand_events') }}
             and (
                  w.days_out_of_stock >= {{ var('demand_supply_oos_min_days') }}
                  or w.cart_adds_while_oos > 0
                 )
            then 'missed_opportunity'
        -- interest climbing while end-of-week stock is not building up
        when w.views_prior_4wk_avg >= {{ var('demand_supply_trend_min_base_views') }}
             and w.item_views >= {{ var('demand_supply_trend_ratio') }} * w.views_prior_4wk_avg
             and w.shippable_eow <= w.shippable_eow_prior_4wk_avg
            then 'restock_risk'
        -- stock sitting there, nobody looking
        when (w.item_views + w.cart_adds) <= {{ var('demand_supply_promote_max_events') }}
             and w.avg_shippable_qty > 0
            then 'promote_candidate'
        else 'healthy'
    end                                                                  as signal
from windowed as w
inner join {{ ref('int_jdawms_items') }} as i
    on i.prtnum = w.prtnum
