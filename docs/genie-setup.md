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
than dumping all 30 objects in.

**Reporting marts (the primary answer surface):**
- `ust_databricks.ust_reporting.mart_customer_engagement`
- `ust_databricks.ust_reporting.mart_customer_product_interactions`
- `ust_databricks.ust_reporting.mart_sales_rep_daily_activity`
- `ust_databricks.ust_reporting.mart_sales_rep_customer_visits`
- `ust_databricks.ust_reporting.mart_sales_agent_performance`

**Facts (for detail / drill-down questions):**
- `ust_databricks.ust_facts.fct_customer_events`
- `ust_databricks.ust_facts.fct_sales_rep_events`

**Dimensions (code/label lookups):**
- `ust_databricks.ust_dimensions.dim_event_codes`

Add `mart_system_health`, `mart_team_performance`, `mart_daily_activity`,
`dim_app_sources`, `dim_categories` later if people start asking about device
health or system-event analytics.

---

## 3. General instructions (paste into the space's "Instructions" box)

```
You answer questions about the UST Digital Platform — a B2B ordering system
used by customers (mobile app) and sales reps (iPad / PDA devices).

Data domains:
- Customer engagement & product interest: mart_customer_engagement (one row
  per customer), mart_customer_product_interactions (one row per customer+SKU),
  and the event detail in fct_customer_events.
- Sales rep activity: mart_sales_rep_daily_activity (one row per rep per day),
  mart_sales_rep_customer_visits (one row per rep+customer), and the event
  detail in fct_sales_rep_events.
- Sales order performance from the system event log: mart_sales_agent_performance.

Key vocabulary:
- "customer" = a B2B account, identified by customer_id (e.g. CHA024, POT001,
  ASI168). customer_name may be blank.
- "rep" / "sales rep" / "agent" = a salesperson, identified by username
  (e.g. emilyma, henghear, michaelyap) and grouped by sales_code (territory:
  001, 008, 024, 028, ...).
- "session" = one app login/visit. "event" = one action within a session
  (page view, search, scan, order step).
- "visit" = a rep interacting with a customer.
- SKU = product code. "page" values include Home, Cart, Categories, Backorder,
  My Orders, Purchase History.

Rules:
- Prefer the mart_* tables for aggregate questions; only use fct_* tables when
  the user asks for individual events or specific detail.
- "active" customers/reps = those with activity in the data window; use
  last_session_at / last_visit_date for recency.
- Dates: activity_date / *_date columns are calendar dates. *_at columns are
  timestamps.
- When asked "how many" of something distinct, count the relevant id column.
- The data is a sample (one-month window), so totals are illustrative.
```

---

## 4. Example queries (add each as a certified/"trusted" SQL example)

Genie learns the most from example question → SQL pairs. Add these via
**Add instruction → SQL query** (or "Example queries"). All are valid
Databricks SQL against the POC tables.

**Q: Who are our most engaged customers?**
```sql
select customer_id, customer_name, total_sessions, total_events, active_days,
       last_session_at
from ust_databricks.ust_reporting.mart_customer_engagement
order by total_events desc
limit 20;
```

**Q: How active is customer CHA024?**
```sql
select *
from ust_databricks.ust_reporting.mart_customer_engagement
where customer_id = 'CHA024';
```

**Q: What products does customer POT001 interact with most?**
```sql
select sku, categories_name, total_interactions, total_qty_interacted,
       last_seen_at
from ust_databricks.ust_reporting.mart_customer_product_interactions
where customer_id = 'POT001'
order by total_interactions desc
limit 20;
```

**Q: Which SKUs get the most customer interest overall?**
```sql
select sku, categories_name,
       count(distinct customer_id) as customers,
       sum(total_interactions)     as interactions
from ust_databricks.ust_reporting.mart_customer_product_interactions
group by sku, categories_name
order by interactions desc
limit 20;
```

**Q: Show me sales rep activity by day.**
```sql
select activity_date, username, sales_code, total_events, login_events,
       unique_customers_visited, completed_events, failed_events
from ust_databricks.ust_reporting.mart_sales_rep_daily_activity
order by activity_date desc, total_events desc;
```

**Q: Which reps visited the most customers?**
```sql
select username, sales_code,
       count(distinct customer_id) as customers_visited,
       sum(total_events)           as total_events
from ust_databricks.ust_reporting.mart_sales_rep_customer_visits
group by username, sales_code
order by customers_visited desc;
```

**Q: Which customers has rep emilyma visited and when last?**
```sql
select customer_id, total_sessions, total_events, completed_actions,
       last_visit_date, visit_days
from ust_databricks.ust_reporting.mart_sales_rep_customer_visits
where username = 'emilyma'
order by last_visit_date desc;
```

**Q: Which reps have device battery problems in the field?**
```sql
select username, sales_code, activity_date, min_battery_pct, avg_battery_pct,
       total_events
from ust_databricks.ust_reporting.mart_sales_rep_daily_activity
where min_battery_pct is not null
order by min_battery_pct asc
limit 20;
```

**Q: What were customer CHA024's most recent actions?**
```sql
select started_at, page, title, event_type_label, sku, qty, duration_seconds
from ust_databricks.ust_facts.fct_customer_events
where customer_id = 'CHA024'
order by started_at desc
limit 50;
```

**Q: What's each sales agent's order performance?**
```sql
select activity_date, username, source_code, orders_submitted,
       orders_succeeded, order_success_rate, distinct_customers_touched
from ust_databricks.ust_reporting.mart_sales_agent_performance
order by activity_date desc, orders_submitted desc;
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
