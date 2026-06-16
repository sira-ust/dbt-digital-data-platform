# Genie Space Setup — UST Digital Platform

Step-by-step to stand up a Databricks AI/BI **Genie** space on the POC marts,
plus copy-paste **general instructions** and **example queries** (trusted
assets) that make Genie answer accurately.

Genie reads three things: the **table/column comments** (already populated from
dbt `persist_docs`), the **general instructions** you paste in, and the
**example SQL** you certify. The more of the last two you give it, the better.

---

## 1. Create the space

1. In the Databricks workspace sidebar: **Genie** → **New** (or
   **New → Genie space**).
2. **Name:** `UST Digital Platform`
3. **Warehouse:** the SQL warehouse already in use
   (`/sql/1.0/warehouses/e165fed86011619a`).
4. **Default catalog / schema:** `ust_databricks` / `ust_reporting`.

## 2. Add tables (start narrow — quality over coverage)

Add these and nothing else at first. A focused set gives far better answers
than dumping all objects in.

**Reporting marts (the primary answer surface):**
- `ust_databricks.ust_reporting.mart_order_journey` — one row per order (increment_id × customer); order status, submission timing, behavior segment
- `ust_databricks.ust_reporting.mart_discovery_navigation` — one row per app feature; click-to-add funnel metrics
- `ust_databricks.ust_reporting.mart_catalog_dwell` — one row per catalog category; browse depth and dwell time
- `ust_databricks.ust_reporting.mart_cart_behaviour` — one row per customer; add/remove/qty-change activity, churn ratio

**Fact (for detail / drill-down questions):**
- `ust_databricks.ust_facts.fct_order_cycle` — one row per order; raw cycle metrics without bucketing

**Seed lookups:**
- `ust_databricks.ust_seeds.seed_event_codes` — 8-digit code → human-readable label
- `ust_databricks.ust_seeds.seed_app_sources` — source code → app name + platform
- `ust_databricks.ust_seeds.seed_categories` — category_id → name hierarchy

> **Note:** Page 4 (sales rep field activity) is not yet built — it requires
> the NAV address master for geofencing. Add those marts when available.

---

## 3. General instructions (paste into the space's "Instructions" box)

```
You answer questions about the UST Digital Platform — a B2B ordering and
catalogue system used by customers (mobile app) and sales reps (iPad / PDA).

Data covers three dashboard domains:

- Order journey: mart_order_journey (one row per order increment_id ×
  customer_key). Shows whether orders were submitted, how long they took,
  and behavior segments (Decisive / Planner / Slow Sender). For now these
  are empty — Group 04/09 events land when a fuller extract is loaded.

- Discovery & navigation: mart_discovery_navigation (one row per app feature
  — Recommend, Promo, New, Backorder) shows click-to-add funnel.
  mart_catalog_dwell (one row per catalog category) shows how long customers
  browse each section.

- Cart behaviour: mart_cart_behaviour (one row per customer_key) shows
  add/remove/qty-change events, distinct SKUs added, and churn_ratio
  (removes ÷ adds — high = lots of second-guessing).

Key vocabulary:
- "customer_key" = B2B account identifier: ust_customer_no on sales apps
  (PDA, CatalogFS); username on customer apps (Vegas, Web).
- "click_to_add_rate" = share of customers who clicked a feature and then
  added an item to cart. Higher is better engagement.
- "churn_ratio" = remove_events / add_events per customer. >1 means more
  removals than additions.
- "behavior_segment" (mart_order_journey): Decisive = same-day close,
  Planner = 1-3 days, Slow Sender = 4+ days.
- "pending_priority" (mart_order_journey): H = 8+ days pending, M = 4-7,
  L = 0-3.

Rules:
- Prefer mart_* tables for aggregate questions; only use fct_order_cycle
  when the user asks for individual order detail.
- mart_order_journey rows with is_submitted = false are open/pending orders.
- The data is a sample window, so totals are illustrative.
```

---

## 4. Example queries (add each as a certified/"trusted" SQL example)

Genie learns the most from example question → SQL pairs. Add these via
**Add instruction → SQL query**. All are valid Databricks SQL against the
POC tables.

**Q: Which app features drive the most adds to cart?**
```sql
select feature_name, click_events, add_events, customers_clicked,
       customers_added, click_to_add_rate
from ust_databricks.ust_reporting.mart_discovery_navigation
order by click_to_add_rate desc;
```

**Q: Which catalog categories get the most browsing time?**
```sql
select category_name, view_events, distinct_customers,
       total_dwell_seconds, avg_dwell_seconds
from ust_databricks.ust_reporting.mart_catalog_dwell
order by total_dwell_seconds desc;
```

**Q: Which customers remove the most items relative to what they add?**
```sql
select customer_key, add_events, remove_events, churn_ratio,
       distinct_skus_added, active_cart_days
from ust_databricks.ust_reporting.mart_cart_behaviour
where churn_ratio is not null
order by churn_ratio desc
limit 20;
```

**Q: How many customers added items but never removed any?**
```sql
select count(*) as loyal_cart_customers
from ust_databricks.ust_reporting.mart_cart_behaviour
where remove_events = 0 and add_events > 0;
```

**Q: What is the order breakdown by behavior segment?**
```sql
select behavior_segment, pending_priority,
       count(*)                                          as orders,
       sum(case when is_submitted then 1 else 0 end)    as submitted,
       avg(days_to_close)                               as avg_days_to_close
from ust_databricks.ust_reporting.mart_order_journey
group by behavior_segment, pending_priority
order by orders desc;
```

**Q: Show me open orders with the highest priority (pending 8+ days).**
```sql
select increment_id, customer_key, opened_at, days_pending,
       create_events, submit_fail_events
from ust_databricks.ust_reporting.mart_order_journey
where is_submitted = false and pending_priority = 'H'
order by days_pending desc;
```

**Q: Which catalog categories have customers browsing the longest per visit?**
```sql
select category_name, view_events, avg_dwell_seconds,
       total_dwell_seconds / nullif(distinct_customers, 0) as avg_seconds_per_customer
from ust_databricks.ust_reporting.mart_catalog_dwell
order by avg_dwell_seconds desc
limit 10;
```

---

## 5. Test & iterate

Ask the sample questions above in the Genie chat. When an answer is wrong:
- If Genie picked the wrong table → tighten the **general instructions**.
- If it wrote slightly wrong SQL → add the correct query as a **certified
  example**.
- If it misread a column → improve that **column comment** in the dbt yml,
  re-run `dbt run --target databricks` for that model (comments re-persist),
  then refresh metadata in the space.

## 6. Keeping metadata fresh

Every `dbt run --target databricks` re-applies the yml descriptions as Unity
Catalog comments (`+persist_docs` is on). So the workflow is: improve a
description in the model's yml → rebuild that model → Genie sees it. No manual
comment editing in Databricks.
