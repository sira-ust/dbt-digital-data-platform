-- Q3: Items where interest is climbing while end-of-week stock isn't
-- building up — early warning for a future stockout. Latest observed week;
-- ranked by how far this week's views beat the item's own baseline.
--
-- NOTE: this signal is rare by design (9 hits across 6 months of history
-- as of 2026-07-14) — a single week easily returns 0 rows. If this query
-- comes back empty, widen to the trailing 4-6 weeks (change the where
-- clause to m.week_start >= date_sub(current_date(), 42)) before assuming
-- nothing is trending.

-- NOTE: if your SQL editor lets you run a highlighted selection, select
-- this ENTIRE statement — running just part of it will error.

select
    m.prtnum,
    m.item_name,
    m.item_family,
    m.abc_class,
    m.week_start,
    m.item_views,
    m.views_prior_4wk_avg,
    round(m.item_views / nullif(m.views_prior_4wk_avg, 0), 2)   as views_vs_baseline_ratio,
    m.shippable_eow,
    m.shippable_eow_prior_4wk_avg,
    m.inbound_qty_peak
from ust_databricks.ust_reporting.mart_item_demand_supply as m
where m.signal = 'restock_risk'
  and m.week_start = (
        select max(week_start) from ust_databricks.ust_reporting.mart_item_demand_supply
      )
order by views_vs_baseline_ratio desc
