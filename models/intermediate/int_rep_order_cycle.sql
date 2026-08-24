-- int_rep_order_cycle — order-cycle reconstruction at cycle grain.
-- One row per matched open → close pair (username × increment_id).
-- Only successful submissions (l3=01) are used as close events — a failed
-- send does not constitute a completed cycle.
--
-- Create Order events (l1=09) carry a device-side local_id in the response;
-- Send Order success events (l1=04, l3=01) carry the server-assigned
-- increment_id — in KV format for PDA/CatalogFS events, or bare value
-- (e.g. "M000123456") for Vegas/CatalogFC events. payload_format from
-- seed_event_codes drives which parse strategy is used.
-- The two ID spaces never overlap so direct ID joins are impossible. Cycles
-- are matched via temporal LEFT JOIN: for each close, find the closest Create
-- Order event that precedes it for the same username + customer, then keep
-- only 1:1 pairs via dual ROW_NUMBER.
--
-- Excludes 09060000 (BLE use-existing) and 09070000 (BLE merge).
--
-- PAYLOAD CHANGE, July 2026. Create Order used to send 'customer, local_id' and
-- this model read the local_id from position 2. The app team then added a
-- dedicated ust_customer_no field and dropped the prefix, so the payload is now
-- a bare local_id. Position 2 became empty, `where local_id is not null` threw
-- every row away, and the model produced NOTHING from 2026-07-20 onward — no
-- error, just an empty table, and mart_rep_order_journey with it. Fixed by
-- accepting either shape and taking the customer from the column.

with events as (

    select * from {{ ref('int_events_enriched') }}

),

create_events as (

    select
        username,
        sales_code,
        source_code,
        app_version,
        event_at_utc,
        -- TWO PAYLOAD ERAS, both live, so the parse branches on the SHAPE of the
        -- row rather than on a date — July 2026 is genuinely mixed (1,677 comma
        -- vs 1,560 bare), so no cutover date can separate them.
        --
        --   legacy  'AAA002, 019-260504-001'  customer, then the order id
        --   current '019-260504-001'          order id only
        --
        -- The app team added a dedicated ust_customer_no field in July 2026 and
        -- dropped the payload prefix (confirmed with the app dev, 2026-08-21), so
        -- for current rows the customer comes from that column via customer_key.
        -- Reading position 1 on a bare row returns the ORDER ID, and position 2
        -- returns nothing, which is why every row was discarded and this model
        -- produced NOTHING from 2026-07-20 on.
        --
        -- Branching (rather than coalescing) keeps legacy rows bit-identical to
        -- the previous behaviour: verified 2026-08-21, May 1,601 and June 1,926
        -- cycles before and after. Coalescing did NOT — it shifted opens into the
        -- dual-rank 1:1 match below and silently cost ~40 real cycles in June.
        case
            when response like '%,%' then {{ response_part('response', 1) }}
            else customer_key
        end                                                            as order_customer_no,
        case
            when response like '%,%' then {{ response_part('response', 2) }}
            -- shape-checked: rep-date-seq, e.g. 031-260803-001
            else nullif(regexp_extract(trim(response),
                                       '^[0-9]{3}-[0-9]{6}-[0-9]{3}$', 0), '')
        end                                                            as local_id
    from events
    where l1_category_name = 'Create Order'
      -- 09060000 (use existing order on catalog) and 09070000 (merge orders)
      -- reference an order that already exists, so they must not OPEN a cycle.
      -- 09050000 (BLE-only create) is a genuine new order and is kept.
      and description_code not in ('09060000', '09070000')
      and actor_type = 'sales'

),

send_events as (

    select
        username,
        customer_key,
        event_at_utc,
        case
            when expected_payload_format = 'kv'
                then {{ parse_kv_response('response', 'increment_id') }}
            else nullif(trim(regexp_extract(response, '([A-Z][0-9]{9})', 1)), '')
        end                                                             as increment_id
    from events
    where l1_category_name = 'Send Order'
      and l3_code = '01'

),

cycle_open as (

    select
        username,
        order_customer_no,
        local_id,
        sales_code,
        source_code,
        app_version,
        min(event_at_utc)                                              as opened_at
    from create_events
    where local_id is not null
    group by
        username, order_customer_no, local_id,
        sales_code, source_code, app_version

),

cycle_close as (

    select
        username,
        customer_key,
        increment_id,
        min(event_at_utc)                                              as submitted_at
    from send_events
    where increment_id is not null
    group by username, customer_key, increment_id

),

matched as (

    select
        c.username,
        c.customer_key                                                 as order_customer_no,
        c.increment_id,
        c.submitted_at,
        o.local_id,
        o.opened_at,
        o.sales_code,
        o.source_code,
        o.app_version,
        row_number() over (
            partition by c.username, c.customer_key, c.increment_id
            order by o.opened_at desc
        )                                                              as open_rank_for_close,
        row_number() over (
            partition by o.username, o.order_customer_no, o.local_id
            order by c.submitted_at asc
        )                                                              as close_rank_for_open
    from cycle_close c
    left join cycle_open o
        on  o.username          = c.username
        and o.order_customer_no = c.customer_key
        and o.opened_at         < c.submitted_at

)

select
    username,
    order_customer_no,
    local_id,
    increment_id,
    sales_code,
    source_code,
    app_version,
    opened_at,
    submitted_at,
    {{ dbt.datediff('opened_at', 'submitted_at', 'day') }}             as days_to_close
from matched
where open_rank_for_close = 1
  and close_rank_for_open = 1
