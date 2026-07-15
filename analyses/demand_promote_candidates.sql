-- Q2: Items with stock on hand but little/no app interest — candidates to
-- promote or discount. Latest observed week; ranked by stock held (biggest
-- carrying-cost items first). Persistent overstock, not a one-week blip —
-- roll up over trailing weeks the same way as Q1 (see demand_missed_opportunity.sql)
-- if you want to filter to items flagged every week, not just this one.

-- NOTE: if your SQL editor lets you run a highlighted selection, select
-- this ENTIRE statement — running just part of it will error.

select
    m.prtnum,
    m.item_name,
    m.item_family,
    m.abc_class,
    m.velocity_zone,
    m.week_start,
    m.item_views,
    m.cart_adds,
    m.demand_events,
    m.avg_shippable_qty,
    m.avg_on_hand_qty,
    m.shippable_eow
from ust_databricks.ust_reporting.mart_item_demand_supply as m
where m.signal = 'promote_candidate'
  and m.week_start = (
        select max(week_start) from ust_databricks.ust_reporting.mart_item_demand_supply
      )
order by m.avg_on_hand_qty desc
