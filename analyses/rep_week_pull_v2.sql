-- rep_week_pull, rolled up to three scenarios.
--
-- GRAIN: one row per REP x CUSTOMER x DAY x SCENARIO, where scenario is now the
-- rolled-up group rather than the mart's six. v1 returns the six; this returns
-- these three (four, once a day with no GPS shows up):
--
--   Onsite                 the rep was physically at the store
--   Remote                 the rep did the work, but not at the store
--   Customer Self Service  the customer ordered on the website, no rep involved
--   Unknown                no GPS that day -- we cannot say where he was
--
-- PLAIN DATABRICKS SQL ON PURPOSE -- copy this whole file into a SQL editor and
-- run it. No dbt compile, no Jinja.
--
-- EDIT TWO THINGS: the sales_code list and the date range, both in `params`.
--
-- ── WHAT ROLLS INTO WHAT ──────────────────────────────────────────────────
--   Onsite   <- on-site, visited keyed elsewhere, visit only no app
--   Remote   <- remote, text/email order
--   Self     <- customer ordered online
--
-- 'visited, keyed elsewhere' is ONSITE. The rep was at the store, built the
-- order there, walked out, and pressed send from the kerb -- rep 018 does this
-- on every order, iPad in the shop and PDA in the car. It is also the biggest
-- bucket of visit-originated money; for these four reps in the week of
-- 2026-09-06 it is $167,256, MORE than 'on-site' itself at $127,225. Move it to
-- Remote and Onsite value more than halves, and 018 reads as a rep who visits
-- stores and sells nothing in them. One line in the case below if you disagree.
--
-- 'text/email order' is Remote, not self-service: the rep still keyed it. It is
-- INFERRED, a strict subset of remote where he keyed a big order in one fast
-- sitting, barely browsed, and typed every line.
--
-- 'unknown' gets its own value rather than folding into Remote. It means there
-- was NO GPS that day, or the customer has no coordinates. Calling that Remote
-- would report absence of evidence as evidence of absence. The final `else`
-- catches it, so any scenario added to the mart later lands in Unknown and is
-- visible rather than quietly inflating Remote.
--
-- ── THE ONE THING THIS ROLLUP MUST NOT DO ─────────────────────────────────
-- fence_minutes is a REP x CUSTOMER x DAY value, repeated identically on every
-- scenario row for that customer-day. Collapsing two rows into one Onsite row
-- therefore takes MAX, never SUM -- 018's ASI282 visit on 09-08 is 71 minutes
-- and appears on both its rows; summed it reads 142. Getting this wrong
-- inflated one rep's week by 54% in an earlier report.
--
-- on_site_minutes and keying_minutes ARE summed: those are per-portion and do
-- not overlap -- the on-site half carries the in-store minutes and the
-- keyed-elsewhere half carries the minutes after he left.

with params as (

    select
        array('002', '003', '007', '008', '018', '019', '024',
              '025', '026', '029', '030', '031', '032')               as reps,
        date '2026-09-14'                                             as from_date,
        date '2026-09-18'                                             as to_date

),

contacts as (

    select
        m.*,
        case
            when m.scenario in ('on-site',
                                'visited, keyed elsewhere',
                                'visit only, no app')  then 'Onsite'
            when m.scenario in ('remote',
                                'text/email order')    then 'Remote'
            when m.scenario = 'customer ordered online'
                                                       then 'Customer Self Service'
            else 'Unknown'
        end                                                           as scenario_group
    from ust_databricks.ust_reporting.mart_rep_customer_activity as m
    cross join params as p
    where array_contains(p.reps, m.sales_code)
      and m.activity_date between p.from_date and p.to_date
      -- the mart's own noise filter: measurable device time, an order, or he
      -- was physically there
      and m.has_activity

),

order_ids_flat as (

    select customer_day_key, scenario, explode(order_ids)             as increment_id
    from contacts

),

-- credited to the contact that SENT the order, so summing counts each order
-- once.
--
-- order_skus is fct_orders.total_item_count: the number of DISTINCT PRODUCTS on
-- the order. It is NOT units and NOT cases. Named order_skus rather than
-- order_lines because "lines" was read as quantity: 84 orders in the week of
-- 2026-09-14 carry total_item_count = 1 with a median of $164 and a maximum of
-- $6,240, and no single case costs $6,240 -- that 1 is one product bought in
-- bulk. Median across all orders is $104 per SKU.
--
-- Quantity is NOT AVAILABLE anywhere at this grain. fct_orders has only
-- grand_total, subtotal and total_item_count, and navrep.sales_invoice_header
-- carries no Magento reference, so there is no join from an increment_id to the
-- NAV lines that hold quantity and unit of measure. Getting cases would need a
-- daily snapshot of navrep.sales_header, which holds m2_order_no only while the
-- order is still open.
order_money as (

    select
        e.customer_day_key,
        e.scenario,
        round(sum(o.grand_total), 2)                                  as order_value,
        sum(o.total_item_count)                                       as order_skus
    from order_ids_flat as e
    join ust_databricks.ust_facts.fct_orders as o
        on o.increment_id = e.increment_id
    where e.increment_id is not null
    group by e.customer_day_key, e.scenario

),

next_order as (

    select
        c.customer_day_key,
        min(o.submitted_date_local)                                   as next_order_date
    from contacts as c
    join ust_databricks.ust_facts.fct_orders as o
        on  o.sales_code   = c.sales_code
        and o.customer_key = c.customer_key
        and o.submitted_date_local >  c.activity_date
        and o.submitted_date_local <= date_add(c.activity_date, 7)
    group by c.customer_day_key

),

joined as (

    select
        c.*,
        coalesce(m.order_value, 0)                                    as row_order_value,
        coalesce(m.order_skus, 0)                                     as row_order_skus,
        n.next_order_date,
        -- which scenario_group gets to report this customer-day's visit.
        -- Onsite first when it exists; otherwise whichever group does -- 15 of
        -- 2,373 visits over 90 days have NO Onsite row (the rep was there, the
        -- customer ordered on the web, and the web branch wins the scenario
        -- case), so anchoring blindly to Onsite would silently drop them.
        dense_rank() over (
            partition by c.sales_code, c.activity_date, c.customer_key
            order by case when c.scenario_group = 'Onsite' then 0 else 1 end,
                     c.scenario_group
        )                                                             as visit_rank
    from contacts as c
    left join order_money as m
        on  m.customer_day_key = c.customer_day_key
        and m.scenario         = c.scenario
    left join next_order as n
        on  n.customer_day_key = c.customer_day_key

)

select
    j.sales_code,
    cast(j.activity_date as string)                                   as activity_date,

    date_format(min(coalesce(j.first_touch_local, j.arrived_at)),  'HH:mm') as started,
    date_format(max(coalesce(j.last_touch_local,  j.departed_at)), 'HH:mm') as ended,

    j.customer_key,
    max(j.customer_name)                                              as customer_name,
    max(j.city)                                                       as city,
    -- NAV's `county` holds the STATE code in the US localisation, aliased
    -- upstream. Filter country = 'US' before grouping on it: 'CA' is California
    -- to 3,851 customers and Canada to 11.
    max(j.state)                                                      as state,
    max(j.country)                                                    as country,

    j.scenario_group                                                  as scenario,

    -- ONE ROW PER CUSTOMER-DAY CARRIES THE VISIT; the rest report 0. See the
    -- header. max() alone fixed the within-group repeat but not the across-
    -- group one: a customer who ordered on the WEB on a day the rep also
    -- visited produces a Customer Self Service row AND an Onsite row, and both
    -- inherited the same fence_minutes. 029 / PHO003 / 2026-09-15 is one --
    -- 51 minutes counted twice. Rare (2 customer-days in this week, 69 minutes)
    -- but it makes sum(fence_minutes) wrong, which is exactly the class of bug
    -- this rollup exists to prevent.
    case when j.visit_rank = 1 then max(coalesce(j.visit_minutes, 0))
         else 0 end                                                   as fence_minutes,
    case when j.visit_rank = 1 then max(coalesce(j.visit_stops, 0))
         else 0 end                                                   as stops,
    -- per-portion and non-overlapping, so these sum correctly. NOTE that
    -- on_site_minutes can land on a non-Onsite row: if the customer ordered on
    -- the web while the rep stood in the shop, the web branch wins the mart's
    -- scenario case and takes the overlap with it. 12 customer-days and 483
    -- minutes over 90 days. Odd to read, but the arithmetic is right.
    sum(j.on_site_worked_minutes)                                     as on_site_minutes,
    sum(j.keying_minutes)                                             as keying_minutes,
    sum(j.pda_minutes)                                                as pda_minutes,
    sum(j.ipad_minutes)                                               as ipad_minutes,
    sum(j.paired_minutes)                                             as paired_minutes,

    sum(j.sessions)                                                   as sessions,
    sum(j.event_count)                                                as event_count,

    sum(j.orders_submitted)                                           as orders_submitted,
    sort_array(array_distinct(flatten(collect_list(j.order_ids))))    as order_ids,
    round(sum(j.row_order_value), 2)                                  as order_value,
    sum(j.row_order_skus)                                             as order_skus,
    datediff(max(j.next_order_date), j.activity_date)                 as days_to_order,

    -- true if ANY row in the group was unresolved
    max(case when j.is_ambiguous then 1 else 0 end) = 1               as is_ambiguous,

    date_format(min(j.arrived_at), 'HH:mm')                           as gps_arrived

from joined as j
group by
    j.sales_code,
    j.activity_date,
    j.customer_key,
    j.scenario_group,
    j.visit_rank
order by
    j.sales_code,
    j.activity_date,
    min(coalesce(j.first_touch_local, j.arrived_at)),
    j.customer_key
