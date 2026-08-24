-- int_rep_customer_activity — assigns every rep work event to a REP-CUSTOMER-DAY,
-- and to a SESSION within it. Event grain: one row per qualifying event, stamped
-- with customer_day_key, session_seq, the device stint, and its dwell.
--
-- This is the shared spine for both consumer marts, so the gap heuristic is
-- defined exactly once:
--   mart_rep_customer_activity         rolls this up per rep x customer x day
--   mart_rep_customer_activity_events   presents this at event grain for drill-down
--
-- A SESSION = one stretch of a rep's work on ONE customer, ended by an idle gap of
-- var('activity_gap_minutes') (30) or more. Tighter than cycle_gap_minutes (60),
-- which is tuned for "same shopping cycle" and survives a lunch break.
--
-- Sessions for DIFFERENT customers may overlap in wall-clock time, and that is
-- correct, not a bug. Reps demonstrably work several customers at once: 41% of
-- customer switches on the real mirror happen within 60 SECONDS, and 6,380 of
-- them within 10 seconds (2026-08-13). Nobody drives to another store in ten
-- seconds — they are flipping between open orders on the device, which the app
-- supports (see the "Merge Orders" and "Use Existing Order on Catalog" codes in
-- seed_event_codes).
--
-- So this model deliberately does NOT reconstruct a route. It measures app
-- usage per customer. An earlier version broke a session whenever the rep
-- switched customer, to force stops to be sequential — that fragmented a
-- single sitting into a dozen "stops" and was removed. Physical presence is
-- out of scope entirely — no timing rule gets there, and GPS was profiled
-- 2026-08-13 and found too loose (see mart_rep_customer_activity).
--
-- APPROXIMATE, same root cause as fct_order_cycles: cart events carry no order
-- number, so a session is inferred from idle gaps rather than declared by the
-- app. Exact per row: customer, device, timestamp, and increment_id on submits.
--
-- WORK EVENTS ONLY: cart edits + discovery features + the order family (09
-- create, 04 send). Background chatter (network/battery/GPS pings) is excluded
-- so it can't inflate a duration. Note that 01040100 Location-Success does
-- carry customer_key AND lat/lon and would make a good physical check-in
-- signal, but its cadence is unprofiled, so it stays out.
--
-- BLE PAIRING. An iPad paired to a PDA over BLE hands its open cart to the PDA,
-- so its own events arrive with no customer. That is REPAIRED UPSTREAM in
-- int_events_enriched (see its header for the mechanism and the measurements) —
-- four models filter on customer_key and all four were losing the same events,
-- so the fix belongs there, not here. This model just consumes the result:
-- customer_key is already resolved, customer_key_source says whether it was
-- declared by the app or inherited, and device_group treats a paired PDA + iPad
-- as the ONE workstation it is, which is what keeps stint timing honest.

with raw_events as (

    select
        entity_id,
        sales_code,
        -- already BLE-resolved upstream: int_events_enriched fills a customer in
        -- when a pairing had moved the open cart to the PDA and the iPad's own
        -- events arrived without one. customer_key_source says which.
        customer_key,
        customer_key_source,
        is_ble_paired,
        ble_pda_device,
        event_at_utc,
        -- the rep's wall clock, computed ONCE in int_events_enriched so this
        -- model and int_rep_customer_presence can never read a visit and the
        -- session inside it against different offsets. They each used to take
        -- their own modal vote and disagreed on 33% of rep-days.
        event_at_local,
        rep_day_offset_hours,
        rep_local_date,

        -- the three sales-facing sources, named the way a sales manager says
        -- them. actor_type = 'sales' already limits us to exactly these.
        case
            when app_name = 'PDA'                                    then 'PDA'
            when app_name = 'CatalogFS' and app_platform = 'iOS'     then 'iPad'
            when app_name = 'CatalogFS' and app_platform = 'Android' then 'Android tablet'
        end                                                              as device,

        -- while paired the two devices are ONE workstation: the rep drives the
        -- iPad from the PDA, so events alternate every few seconds. Splitting a
        -- stint on every flip bills the gap between them to neither device —
        -- rep 026 / JUN003 / 2026-08-17 reported pda_minutes = 0 on a session
        -- holding 5 PDA events, because each stint collapsed to 0 seconds.
        case
            when is_ble_paired                        then 'PDA + iPad (paired)'
            when app_name = 'PDA'                     then 'PDA'
            when app_name = 'CatalogFS'
                 and app_platform = 'iOS'             then 'iPad'
            when app_name = 'CatalogFS'
                 and app_platform = 'Android'         then 'Android tablet'
        end                                                              as device_group,

        description_code,
        function_name,
        feature_name,
        page_context,
        is_add,
        is_remove,
        is_qty_change,

        -- submit = server-side order receipt carrying the KV payload; this is
        -- the ONE event that names an order.
        (l1_code = '04' and response like '%increment_id:%')              as is_submit,
        case
            when l1_code = '04' and response like '%increment_id:%'
                then {{ parse_kv_response('response', 'increment_id') }}
        end                                                              as increment_id
    from {{ ref('int_events_enriched') }}
    where actor_type   = 'sales'
      and sales_code   is not null
      and customer_key is not null
      and event_at_utc is not null
      and (
            is_add or is_remove or is_qty_change
            or feature_name is not null
            or l1_code in ('04', '09')
          )

),

events as (

    -- columns listed explicitly: `* except`/`* exclude` spelling differs
    -- between databricks and duckdb, so neither is portable here.
    select
        e.entity_id,
        e.sales_code,
        e.customer_key,
        e.customer_key_source,
        e.is_ble_paired,
        e.ble_pda_device,
        e.event_at_utc,
        e.device,
        e.device_group,
        e.description_code,
        e.function_name,
        e.feature_name,
        e.page_context,
        e.is_add,
        e.is_remove,
        e.is_qty_change,
        e.is_submit,
        e.increment_id,
        e.event_at_local,
        e.rep_day_offset_hours,
        e.rep_local_date
    from raw_events as e
    -- no shared clock means no rep-local time; such an event cannot be placed
    -- on a day or inside a visit, so it is dropped rather than guessed at
    where e.event_at_local is not null

),

-- windows run over ONE CUSTOMER's timeline for that rep, so a session measures
-- time spent on that customer regardless of what else the rep interleaved.
sequenced as (

    select
        *,
        lag(event_at_utc) over (
            partition by sales_code, customer_key order by event_at_utc, entity_id
        )                                                                as prev_at,
        lag(device_group) over (
            partition by sales_code, customer_key order by event_at_utc, entity_id
        )                                                                as prev_device_group
    from events

),

flagged as (

    select
        *,
        case
            when prev_at is null                                          then 1
            when {{ dbt.datediff('prev_at', 'event_at_utc', 'minute') }}
                 >= {{ var('activity_gap_minutes') }}                        then 1
            else 0
        end                                                              as is_new_session
    from sequenced

),

numbered as (

    select
        *,
        sum(is_new_session) over (
            partition by sales_code, customer_key
            order by event_at_utc, entity_id
            rows between unbounded preceding and current row
        )                                                                as session_seq,
        -- a new device stint starts on a new session OR whenever the device
        -- changes hands. coalesce (not IS DISTINCT FROM) keeps this portable
        -- across duckdb and databricks.
        sum(
            case
                when is_new_session = 1                                   then 1
                when coalesce(device_group, '?')
                     <> coalesce(prev_device_group, '?')                  then 1
                else 0
            end
        ) over (
            partition by sales_code, customer_key
            order by event_at_utc, entity_id
            rows between unbounded preceding and current row
        )                                                                as stint_seq
    from flagged

)

select
    entity_id,

    -- The grain both marts report on: one rep, one customer, one day.
    sales_code || '-' || customer_key || '-'
        || cast(rep_local_date as {{ dbt.type_string() }})                as customer_day_key,

    sales_code,
    customer_key,
    rep_local_date                                                       as activity_date,
    session_seq,
    stint_seq,

    event_at_utc,
    event_at_local,
    -- published so the shared-clock invariant with int_rep_customer_presence is
    -- TESTABLE, not merely asserted in a comment. Both take this from
    -- int_events_enriched; they must never differ. See
    -- tests/assert_presence_and_activity_share_one_clock.sql
    rep_day_offset_hours,

    row_number() over (
        partition by sales_code, customer_key, rep_local_date
        order by event_at_utc, entity_id
    )                                                                    as event_seq,

    -- dwell on the PREVIOUS step. Null on the first event of a session: the gap
    -- before it is idle time, not work on this customer.
    case
        when is_new_session = 1 then null
        else {{ dbt.datediff('prev_at', 'event_at_utc', 'second') }}
    end                                                                  as seconds_since_prev_event,

    device,
    -- 'PDA + iPad (paired)' while BLE-paired: one workstation, not two devices
    device_group,
    is_ble_paired,
    ble_pda_device,
    -- 'event' = the app named the customer; 'ble_session' / 'paired_pda' = we
    -- inherited it because a BLE pairing had moved the cart to the PDA. Anything
    -- that must be exact should filter to 'event'.
    customer_key_source,
    description_code,
    function_name,
    feature_name,
    page_context,
    is_add,
    is_remove,
    is_qty_change,
    is_submit,
    increment_id
from numbered
