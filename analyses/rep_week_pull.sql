-- The extract behind the field-coverage HTML. One row per contact, in the
-- shape the page's DATA array expects -- run it, export JSON, paste it in.
--
-- dbt does NOT run analyses/. `dbt compile` renders this into target/compiled/
-- and you copy it into a SQL editor. Nothing here is materialised.
--
-- EDIT TWO THINGS: the sales_code list and the date range, both in `params`.
--
-- FILTER ON sales_code, NEVER username. Rep 028 appears as both 'charliechang'
-- and 'Charliechang' in the event log; keying on username silently drops rows.
--
-- GRAIN: one row per REP x CUSTOMER x DAY x SCENARIO, straight from the mart.
-- A customer worked both on-site and after leaving produces TWO rows, which is
-- the point -- the page draws them as two chips and shows which one sent the
-- order. count(*) is therefore NOT a visit count; count distinct customer_key.
--
-- THIS USED TO NEED FOUR JOINS. customer_name, the visit window and the order
-- placement all moved onto the mart on 2026-09-15, so the only thing left to
-- join is fct_orders for money. Everything that reconstructed those by hand got
-- something wrong: fence minutes are a customer-DAY value, so summing them once
-- per scenario row double-counts a customer worked on both sides of the
-- departure, and that inflated one rep's week by 54%.
--
-- FRESHNESS: the mart trails the event log by about a day. Check before you
-- report on "today":
--     select max(activity_date) from {{ ref('mart_rep_customer_activity') }};

with params as (

    select
        array('018', '029', '030', '032')                             as reps,
        date '2026-09-06'                                             as from_date,
        date '2026-09-11'                                             as to_date

),

contacts as (

    select m.*
    from {{ ref('mart_rep_customer_activity') }} as m
    cross join params as p
    where array_contains(p.reps, m.sales_code)
      and m.activity_date between p.from_date and p.to_date
      -- the mart's own noise filter: measurable device time, an order, or he
      -- was physically there. NOT event_count -- a submit with no preceding
      -- cart activity is one event and legitimate, and `>= 4` discards 31% of
      -- all orders.
      and m.has_activity

),

-- ── money, the one thing still worth a join ───────────────────────────────
-- Credited to the contact that SENT the order. orders_submitted has been keyed
-- to the session portion since 2026-09-15, so a row carries an order only if
-- its own submit fired inside it -- summing these is safe.
--
-- order_lines is fct_orders.total_item_count: DISTINCT SKUs, not units and not
-- cases. An order for 4 lines at 30 cases each reads 4. Cases cannot be joined
-- here at all -- nothing links a Magento order number to the NAV lines that
-- carry unit of measure once the order closes.
-- exploded in its own pass: a lateral view cannot be followed by a join in
-- Spark, and the unnest macro keeps this readable on DuckDB too
order_lines_flat as (

    select
        customer_day_key,
        scenario,
        {{ unnest('order_ids') }}                                     as increment_id
    from contacts

),

order_money as (

    select
        e.customer_day_key,
        e.scenario,
        round(sum(o.grand_total), 2)                                  as order_value,
        sum(o.total_item_count)                                       as order_lines
    from order_lines_flat as e
    join {{ ref('fct_orders') }} as o
        on o.increment_id = e.increment_id
    where e.increment_id is not null
    group by e.customer_day_key, e.scenario

),

-- ── did the customer order SOON AFTER a visit that captured nothing? ──────
-- Half the "no order" visits are not barren: the order rides the next batch
-- sync. The PDA queues submits and flushes them together -- rep 018 logged four
-- orders for four customers at 13:25:43-44 on 2026-09-08, one device, one
-- created_at_utc. Without this the page tints those visits as failures.
next_order as (

    select
        c.customer_day_key,
        min(o.submitted_date_local)                                   as next_order_date
    from contacts as c
    join {{ ref('fct_orders') }} as o
        on  o.sales_code   = c.sales_code
        and o.customer_key = c.customer_key
        and o.submitted_date_local >  c.activity_date
        and o.submitted_date_local <= {{ dbt.dateadd('day', 7, 'c.activity_date') }}
    group by c.customer_day_key

)

select
    c.sales_code,
    cast(c.activity_date as {{ dbt.type_string() }})                  as activity_date,

    -- TWO CLOCKS. first_touch_local is when he WORKED the customer on the
    -- device and is null on 'visit only, no app' by construction -- that
    -- scenario means there was no app activity to time. arrived_at is when he
    -- was physically there. Both are published raw below so a row's clock is
    -- visible rather than guessed.
    {{ format_hhmm('coalesce(c.first_touch_local, c.arrived_at)') }}   as started,
    {{ format_hhmm('coalesce(c.last_touch_local,  c.departed_at)') }}  as ended,

    c.customer_key,
    c.customer_name,
    c.scenario,
    c.scenario in ('on-site', 'visited, keyed elsewhere',
                   'visit only, no app')                              as is_visit,

    -- the VISIT: how long he was inside the geofence, across every stop
    coalesce(c.visit_stops, 0)                                        as stops,
    coalesce(c.visit_minutes, 0)                                      as fence_minutes,
    -- the WORKED portion: how much of that visit a device session covered. 0 on
    -- every keyed-elsewhere row by definition. Renamed from on_site_minutes,
    -- which read as time on site and is not.
    c.on_site_worked_minutes                                          as on_site_minutes,

    c.keying_minutes,
    c.pda_minutes,
    c.ipad_minutes,
    c.paired_minutes,

    c.sessions,
    -- >1 means started..ended is NOT one continuous stretch, so the row overlaps
    -- the day rather than occupying a slot in it
    c.segments,
    c.event_count,

    c.orders_submitted,
    c.order_ids,
    -- the page reads this to fill the order dot. Now simply "did this row send
    -- one" -- it needed the submit event's timestamp until orders_submitted was
    -- keyed to the session portion.
    case when c.orders_submitted > 0 then 1 else 0 end                as submitted_here,
    coalesce(m.order_value, 0)                                        as order_value,
    coalesce(m.order_lines, 0)                                        as order_lines,
    {{ dbt.datediff('c.activity_date', 'n.next_order_date', 'day') }} as days_to_order,

    -- two live customers in range AND nothing in the app to separate them
    c.is_ambiguous,

    -- which clock this row is using
    {{ format_hhmm('c.first_touch_local') }}                          as app_first_touch,
    {{ format_hhmm('c.arrived_at') }}                                 as gps_arrived

from contacts as c
left join order_money as m
    on  m.customer_day_key = c.customer_day_key
    and m.scenario         = c.scenario
left join next_order as n
    on  n.customer_day_key = c.customer_day_key
order by
    c.sales_code,
    c.activity_date,
    coalesce(c.first_touch_local, c.arrived_at),
    c.customer_key
