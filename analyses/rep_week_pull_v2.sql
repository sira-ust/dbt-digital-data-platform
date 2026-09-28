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

-- ── VERIFIED AGAINST THE WAREHOUSE 2026-09-28 ────────────────────────────────
-- The whole 09-20..09-26 pull was re-run and diffed against the published
-- report: every field identical, and the money reconciled against fct_orders
-- independently ($2,765,953.15 summing distinct orders vs $2,765,953.18 summing
-- these rows -- 3c of per-group rounding). Scenario labels were re-derived from
-- RAW GPS: all but one in-person row had a location ping within 100 m of the
-- customer credited, and 0 of 352 remote rows did. Onsite-vs-Remote-vs-Self-
-- Service is sound.
--
-- Four defects were found. TWO WERE FIXED IN THE MODELS THE SAME DAY and their
-- columns below should now come back EMPTY -- keep them as regression checks,
-- because both bugs were invisible until something looked for them:
--
--   channel_mismatch           fixed in mart_rep_customer_activity: order_channel
--                              is now taken per ORDER instead of max() per
--                              session, so a session holding both a rep-keyed
--                              and a customer-placed order splits into two
--                              scenario rows. 4 -> 0 in this week.
--   visit_unsupported_by_gps   fixed in int_rep_customer_presence: a non-ping
--                              event that replays the device's cached position
--                              is dropped before the speed check. 1 -> 0.
--
-- After the fixes this week returns 641 rows (was 638 -- the channel split adds
-- rows) and 198 in-person rows (was 200 -- two visits rested on a stale
-- coordinate). orders_submitted and order_value are unchanged.
--
-- The other two are NOT fixed and are live measurements, not history:
--
--   no_order_id          the mart counts a submit event whose payload carried
--                        no increment_id (the literal string '(null)'). It
--                        joins to nothing, so it contributed a $0 "order":
--                        rep 002 read 41 orders at $5,845 average against a
--                        true 39 at $6,144. Those are now REMOVED from
--                        orders_submitted and order_ids, and counted here.
--
--   colocated_with       int_rep_customer_presence credits EVERY active
--                        customer within 100 m of a fix, not just the nearest
--                        (deliberate -- its own comment records visit-days
--                        going 8,395 -> 20,410 over six months). This column
--                        names the other customers credited to the same rep-day
--                        whose STORES are within 100 m, so one stop showing up
--                        as several is visible rather than implied. 32 rows in
--                        this week, at most 15 real visits among them.
--
--   geofence_ambiguous   the mart publishes BOTH this and is_ambiguous, and
--   resolved_by_app      they are not the same number: 74 rows had more than one
--                        active customer in the fence but only 32 are flagged by
--                        is_ambiguous, because resolved_by_app suppresses the
--                        rest. Carry both or a page looks more certain than the
--                        data is. STILL OPEN.
--
--   channel_mismatch     FIXED 2026-09-28. Was: the mart read ONE channel per
--                        session via max(order_channel), a lexicographic pick on
--                        a mixed session -- max('APP','PDA') = 'PDA' and
--                        max('PDA','WEB') = 'WEB'. The worst case was 032 /
--                        GOL030 / 09-21, where $38,245 of a $43,898 row was the
--                        CUSTOMER ordering on the app but read as the rep keying
--                        it remotely. Expect 0 rows; anything here is a
--                        regression.
--
--   visit_unsupported    FIXED 2026-09-28. Was: 030 / ANG015 / 09-22 labelled
--        _by_gps         'visited, keyed elsewhere' on the strength of a LOGIN
--                        event replaying the previous day's cached coordinate,
--                        while real pings put him 82 km away all day. Worse, the
--                        stale fix then made the genuine ping look impossible
--                        (61,239 mph) so the speed filter discarded the REAL
--                        reading. Expect 0 rows; anything here is a regression.
--                        NOTE fix_count = 1 alone never meant absent -- 8 of the
--                        9 single-fix rows were genuine brief stops 7-91 m away.
--                        Distance is the evidence.

with params as (

    select
        array('002', '003', '007', '008', '018', '019', '024',
              '025', '026', '029', '030', '031', '032')               as reps,
        date '2026-09-20'                                             as from_date,
        date '2026-09-26'                                             as to_date

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

-- ORDER EVENTS THAT CARRY NO ORDER ID. The payload logged the literal string
-- '(null)' where the increment_id belongs, so the mart's orders_submitted
-- counts a submit that joins to nothing in fct_orders and is worth nothing.
-- Rare but long-running: 1-4 rows a month across the whole mart, 2 in this week
-- (both rep 002 on 09-21, one of them on the Unknown customer, i.e. an order
-- belonging to no customer at all). Counted here so they can be subtracted.
orders_without_id as (

    select customer_day_key, scenario, count(*)                       as orders_without_id
    from order_ids_flat
    where increment_id = '(null)'
    group by customer_day_key, scenario

),

-- ORDERS WHOSE CHANNEL CONTRADICTS THE SCENARIO. See the header: the mart takes
-- max(order_channel) per session, which is a lexicographic pick on a mixed
-- session. Self-service means the CUSTOMER placed it (WEB/APP); every other
-- scenario means the rep keyed it (PDA). Anything else is the bug showing.
channel_mismatch as (

    select
        e.customer_day_key,
        e.scenario,
        sort_array(collect_set(
            concat(e.increment_id, ' is ', o.order_channel)))         as channel_mismatch
    from order_ids_flat as e
    join ust_databricks.ust_facts.fct_orders as o
        on o.increment_id = e.increment_id
    where (e.scenario  = 'customer ordered online' and o.order_channel = 'PDA')
       or (e.scenario <> 'customer ordered online' and o.order_channel in ('WEB', 'APP'))
    group by e.customer_day_key, e.scenario

),

-- HOW MUCH GPS IS BEHIND THE VISIT. A visit built from ONE fix with zero dwell
-- is geometry noise, not a visit -- see visit_is_single_fix in the header.
visit_evidence as (

    select
        sales_code,
        activity_date,
        customer_key,
        sum(fix_count)                                                as visit_fix_count,
        max(on_site_minutes)                                          as visit_max_on_site
    from ust_databricks.ust_intermediate.int_rep_customer_presence
    group by sales_code, activity_date, customer_key

),

-- STOPS THAT CANNOT BE TOLD APART. Every customer credited IN PERSON to this
-- rep-day whose store sits within the same 100 m the geofence uses. If a name
-- appears here it is closer than GPS error, so at most one of the pair is where
-- he actually stood. Computed, not asserted, so it stays right when the date
-- range moves.
in_person as (

    select distinct sales_code, activity_date, customer_key
    from contacts
    where scenario_group = 'Onsite'

),

colocated as (

    select
        a.sales_code,
        a.activity_date,
        a.customer_key,
        sort_array(collect_set(b.customer_key))                       as colocated_with
    from in_person as a
    join ust_databricks.ust_staging.stg_nav__customer_locations as la
        on la.customer_key = a.customer_key and la.latitude is not null
    join in_person as b
        on  b.sales_code    = a.sales_code
        and b.activity_date = a.activity_date
        and b.customer_key <> a.customer_key
    join ust_databricks.ust_staging.stg_nav__customer_locations as lb
        on lb.customer_key = b.customer_key and lb.latitude is not null
    where 2 * 6371000 * asin(sqrt(
              pow(sin(radians(lb.latitude - la.latitude) / 2), 2)
            + cos(radians(la.latitude)) * cos(radians(lb.latitude))
              * pow(sin(radians(lb.longitude - la.longitude) / 2), 2)
          )) <= 100
    group by a.sales_code, a.activity_date, a.customer_key

),

-- HOW CLOSE THE REP ACTUALLY GOT. The decisive test for an in-person label,
-- and independent of the presence model: the smallest distance between ANY raw
-- location ping the rep emitted that day and this customer's store. Only
-- computed for in-person rows, which is the only place it matters.
--
-- ONLY 01040100 (Location-Success), AND THAT IS DELIBERATE -- do not widen it.
-- int_rep_customer_presence accepts every geo-bearing event, which is right for
-- BUILDING visits (a located Create Order says where he stood when he keyed it).
-- But some of those events replay the device's LAST CACHED position, and this
-- column exists to audit presence, so it must not read the same possibly-stale
-- source it is auditing. 030 / ANG015 / 09-22 is exactly that case:
--
--     11:38:51  Login: Username    Honeywell EDA50K        0 m from ANGKOR
--     11:38:54  Location-Success   Honeywell EDA50K   82,130 m from ANGKOR
--
-- Same device, three seconds apart. Every other event that day, on all three of
-- his devices, is ~82 km out; the login replayed the coordinate from the
-- PREVIOUS day's visit, identical to within a metre. A real ping cannot be
-- cached, so pings are the only honest yardstick here.
--
-- In the 09-20 week 199 of 200 in-person rows come back within 100 m; ANG015 is
-- the only one that does not. Note that fix_count = 1 ALONE does not mean
-- absent: 9 rows rest on a single fix and 8 are genuine brief stops 7-91 m
-- away. Distance is the evidence; fix_count is only a hint.
day_pings as (

    select
        e.sales_code,
        e.rep_local_date                                              as activity_date,
        e.latitude,
        e.longitude
    from ust_databricks.ust_intermediate.int_events_enriched as e
    cross join params as p
    where array_contains(p.reps, e.sales_code)
      and e.rep_local_date between p.from_date and p.to_date
      and e.description_code = '01040100'
      and e.latitude  is not null
      and e.longitude is not null

),

gps_proximity as (

    select
        a.sales_code,
        a.activity_date,
        a.customer_key,
        round(min(2 * 6371000 * asin(sqrt(
              pow(sin(radians(g.latitude - l.latitude) / 2), 2)
            + cos(radians(l.latitude)) * cos(radians(g.latitude))
              * pow(sin(radians(g.longitude - l.longitude) / 2), 2)
          ))), 0)                                                     as visit_gps_metres
    from in_person as a
    join ust_databricks.ust_staging.stg_nav__customer_locations as l
        on l.customer_key = a.customer_key and l.latitude is not null
    join day_pings as g
        on  g.sales_code    = a.sales_code
        and g.activity_date = a.activity_date
    group by a.sales_code, a.activity_date, a.customer_key

),

joined as (

    select
        c.*,
        coalesce(m.order_value, 0)                                    as row_order_value,
        coalesce(m.order_skus, 0)                                     as row_order_skus,
        coalesce(w.orders_without_id, 0)                              as row_orders_without_id,
        x.channel_mismatch                                            as row_channel_mismatch,
        v.visit_fix_count,
        v.visit_max_on_site,
        co.colocated_with,
        gp.visit_gps_metres,
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
    left join orders_without_id as w
        on  w.customer_day_key = c.customer_day_key
        and w.scenario         = c.scenario
    left join channel_mismatch as x
        on  x.customer_day_key = c.customer_day_key
        and x.scenario         = c.scenario
    left join visit_evidence as v
        on  v.sales_code    = c.sales_code
        and v.activity_date = c.activity_date
        and v.customer_key  = c.customer_key
    left join colocated as co
        on  co.sales_code    = c.sales_code
        and co.activity_date = c.activity_date
        and co.customer_key  = c.customer_key
    left join gps_proximity as gp
        on  gp.sales_code    = c.sales_code
        and gp.activity_date = c.activity_date
        and gp.customer_key  = c.customer_key
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
    -- the rollup's own definition of "in person", so a consumer never has to
    -- re-derive it from the scenario string. NOTE visit_is_single_fix below:
    -- true there means this is_visit is not supported by the GPS.
    j.scenario_group = 'Onsite'                                       as is_visit,

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

    -- ORDERS, NET OF THE ONES THAT CARRY NO ID. Subtracting here is what makes
    -- this column agree with fct_orders: 528 distinct orders in the 09-20 week,
    -- not the 530 submit events the mart counts.
    sum(j.orders_submitted) - sum(j.row_orders_without_id)            as orders_submitted,
    sum(j.row_orders_without_id)                                      as orders_without_id,
    -- '(null)' is a literal string in the payload, not a SQL NULL, so it has to
    -- be removed by value or it rides along as a phantom order id.
    sort_array(array_except(
        array_distinct(flatten(collect_list(j.order_ids))),
        array('(null)')))                                             as order_ids,
    round(sum(j.row_order_value), 2)                                  as order_value,
    -- DISTINCT SKUs on the order -- not units, not cases. See the header note.
    -- The HTML report's DATA calls this field `order_lines`; same number.
    sum(j.row_order_skus)                                             as order_skus,
    datediff(max(j.next_order_date), j.activity_date)                 as days_to_order,

    -- DID THIS CONTACT PRESS SEND? The mart already moved each submit onto the
    -- session portion it fired in, so a row with orders left after the '(null)'
    -- subtraction is the one that sent them.
    (sum(j.orders_submitted) - sum(j.row_orders_without_id)) > 0      as submitted_here,

    -- ── CONFIDENCE ──────────────────────────────────────────────────────────
    -- true if ANY row in the group was unresolved. This is the mart's PRACTICAL
    -- flag: geometry was ambiguous AND the app did not settle it.
    max(case when j.is_ambiguous then 1 else 0 end) = 1               as is_ambiguous,
    -- the RAW geometry: more than one active customer inside the fence, whether
    -- or not the app later settled it. Strictly wider than is_ambiguous -- 72
    -- rows against 31 in the 09-20 week -- so report both or the page will look
    -- more certain than the data is.
    max(case when j.geofence_ambiguous then 1 else 0 end) = 1         as geofence_ambiguous,
    max(case when j.resolved_by_app    then 1 else 0 end) = 1         as resolved_by_app,
    -- other customers credited in person to this rep-day whose stores are
    -- within 100 m of this one. Non-empty means one stop, several names.
    max(j.colocated_with)                                             as colocated_with,
    -- HOW GOOD IS THE in-person LABEL. visit_gps_metres is the closest any raw
    -- ping got to the store that day -- the real test, and the one that catches
    -- 030 / ANG015 / 09-22 at 78 km. visit_fix_count is a hint only: a single
    -- fix is usually a genuine brief stop, so do NOT drop rows on it alone.
    max(j.visit_fix_count)                                            as visit_fix_count,
    max(j.visit_gps_metres)                                           as visit_gps_metres,
    j.scenario_group = 'Onsite'
        and coalesce(max(j.visit_gps_metres), 0) > 250                as visit_unsupported_by_gps,
    -- any order on this row whose channel contradicts the scenario
    sort_array(array_distinct(flatten(
        collect_list(j.row_channel_mismatch))))                       as channel_mismatch,

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
