-- Q1: Items customers wanted but CABOT couldn't ship.
--
-- Version A (below): latest observed week only — a single week can be thin/
-- noisy (the current week is often partial). Version B (commented out):
-- rolled up over the trailing 4 completed weeks, so an item that repeatedly
-- shows up is easier to distinguish from a one-off blip.

-- NOTE: if your SQL editor lets you run a highlighted selection, make sure
-- to select this ENTIRE statement (including the subquery below) — running
-- just the SELECT on its own will error with "latest_week not found"-style
-- messages depending on how the query is written.

select
    m.prtnum,
    m.item_name,
    m.item_family,
    m.abc_class,
    m.week_start,
    m.item_views,
    m.cart_adds,
    m.cart_adds_while_oos,
    m.views_while_oos,
    m.days_out_of_stock,
    m.snapshot_days,
    m.avg_shippable_qty,
    m.inbound_qty_peak
from ust_databricks.ust_reporting.mart_item_demand_supply as m
where m.signal = 'missed_opportunity'
  and m.week_start = (
        select max(week_start) from ust_databricks.ust_reporting.mart_item_demand_supply
      )
order by m.cart_adds_while_oos desc, m.demand_events desc

-- ── Version B: trailing 4 completed weeks, rolled up per item ──────────
-- with weeks as (
--     select distinct week_start
--     from ust_databricks.ust_reporting.mart_item_demand_supply
--     order by week_start desc
--     offset 1 limit 4   -- offset 1 skips the current, possibly-partial week
-- )
-- select
--     m.prtnum,
--     m.item_name,
--     m.item_family,
--     m.abc_class,
--     count(*)                          as weeks_flagged,
--     sum(m.cart_adds_while_oos)         as cart_adds_while_oos_total,
--     sum(m.views_while_oos)             as views_while_oos_total,
--     sum(m.days_out_of_stock)           as days_out_of_stock_total,
--     avg(m.avg_shippable_qty)           as avg_shippable_qty
-- from ust_databricks.ust_reporting.mart_item_demand_supply as m
-- inner join weeks as w on m.week_start = w.week_start
-- where m.signal = 'missed_opportunity'
-- group by 1, 2, 3, 4
-- order by weeks_flagged desc, cart_adds_while_oos_total desc
