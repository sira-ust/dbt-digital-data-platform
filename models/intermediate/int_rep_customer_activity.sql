-- int_rep_customer_activity — assigns every rep work event to a REP-CUSTOMER-DAY,
-- and to a LOGIN within it. Event grain: one row per qualifying event, stamped
-- with customer_day_key, login_seq, the device stint, and its dwell.
--
-- This is the shared spine for both consumer marts, so the gap heuristic is
-- defined exactly once:
--   mart_rep_customer_activity         rolls this up per rep x customer x day
--   mart_rep_customer_activity_events   presents this at event grain for drill-down
--
-- A LOGIN = a run of one rep's activity on ONE customer with no idle gap of
-- var('activity_gap_minutes') (30) or more. Tighter than cycle_gap_minutes (60),
-- which is tuned for "same shopping cycle" and survives a lunch break.
--
-- Logins for DIFFERENT customers may overlap in wall-clock time, and that is
-- correct, not a bug. Reps demonstrably work several customers at once: 41% of
-- customer switches on the real mirror happen within 60 SECONDS, and 6,380 of
-- them within 10 seconds (2026-08-13). Nobody drives to another store in ten
-- seconds — they are flipping between open orders on the device, which the app
-- supports (see the "Merge Orders" and "Use Existing Order on Catalog" codes in
-- seed_event_codes).
--
-- So this model deliberately does NOT reconstruct a route. It measures app
-- usage per customer. An earlier version broke a login whenever the rep
-- switched customer, to force stops to be sequential — that fragmented a
-- single sitting into a dozen "stops" and was removed. Physical presence is
-- out of scope entirely — no timing rule gets there, and GPS was profiled
-- 2026-08-13 and found too loose (see mart_rep_customer_activity).
--
-- APPROXIMATE, same root cause as fct_order_cycles: cart events carry no order
-- number, so a login is inferred from idle gaps rather than declared by the
-- app. Exact per row: customer, device, timestamp, and increment_id on submits.
--
-- WORK EVENTS ONLY: cart edits + discovery features + the order family (09
-- create, 04 send). Background chatter (network/battery/GPS pings) is excluded
-- so it can't inflate a duration. Note that 01040100 Location-Success does
-- carry customer_key AND lat/lon and would make a good physical check-in
-- signal, but its cadence is unprofiled, so it stays out.

with raw_events as (

    select
        entity_id,
        sales_code,
        customer_key,
        event_at_utc,
        cast(event_at_utc as date)                                       as utc_date,
        coalesce({{ tz_offset_hours('device_timezone') }}, 0)            as row_offset_hours,

        -- the three sales-facing sources, named the way a sales manager says
        -- them. actor_type = 'sales' already limits us to exactly these.
        case
            when app_name = 'PDA'                                    then 'PDA'
            when app_name = 'CatalogFS' and app_platform = 'iOS'     then 'iPad'
            when app_name = 'CatalogFS' and app_platform = 'Android' then 'Android tablet'
        end                                                              as device,

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

-- ONE timezone offset per rep-day, not per event.
--
-- device_timezone is a device setting, not a location: only 43% of rep-days
-- carry a single value on the real mirror (2026-08-13) — rep 007 logged GMT-8,
-- GMT-7 AND GMT-6 on one day. Converting each event with its own row's offset
-- makes local time non-monotonic with UTC, which scrambles the order of a
-- customer-day's events and made the summary and drill-down disagree on when
-- the work started.
--
-- So: take the MODAL offset for the rep's day and apply it to every event that
-- day. Ties break toward the offset closest to UTC for determinism. Login
-- boundaries are computed in UTC and are unaffected by this — the offset only
-- decides what wall clock the work is displayed against.
rep_day_offset as (

    select sales_code, utc_date, row_offset_hours as offset_hours
    from (
        select
            sales_code,
            utc_date,
            row_offset_hours,
            row_number() over (
                partition by sales_code, utc_date
                order by count(*) desc, abs(row_offset_hours)
            )                                                            as rn
        from raw_events
        group by sales_code, utc_date, row_offset_hours
    ) as ranked
    where rn = 1

),

events as (

    -- columns listed explicitly: `* except`/`* exclude` spelling differs
    -- between databricks and duckdb, so neither is portable here.
    select
        e.entity_id,
        e.sales_code,
        e.customer_key,
        e.event_at_utc,
        e.device,
        e.description_code,
        e.function_name,
        e.feature_name,
        e.page_context,
        e.is_add,
        e.is_remove,
        e.is_qty_change,
        e.is_submit,
        e.increment_id,
        -- the rep's wall clock, so "Monday" and "10:40am" are the rep's
        {{ add_hours('e.event_at_utc', 'o.offset_hours') }}               as event_at_local
    from raw_events as e
    join rep_day_offset as o
        on o.sales_code = e.sales_code
       and o.utc_date   = e.utc_date

),

-- windows run over ONE CUSTOMER's timeline for that rep, so a login measures
-- time spent on that customer regardless of what else the rep interleaved.
sequenced as (

    select
        *,
        lag(event_at_utc) over (
            partition by sales_code, customer_key order by event_at_utc, entity_id
        )                                                                as prev_at,
        lag(device) over (
            partition by sales_code, customer_key order by event_at_utc, entity_id
        )                                                                as prev_device
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
        end                                                              as is_new_login
    from sequenced

),

numbered as (

    select
        *,
        sum(is_new_login) over (
            partition by sales_code, customer_key
            order by event_at_utc, entity_id
            rows between unbounded preceding and current row
        )                                                                as login_seq,
        -- a new device stint starts on a new login OR whenever the device
        -- changes hands. coalesce (not IS DISTINCT FROM) keeps this portable
        -- across duckdb and databricks.
        sum(
            case
                when is_new_login = 1                                   then 1
                when coalesce(device, '?') <> coalesce(prev_device, '?')   then 1
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
        || cast(cast(event_at_local as date) as {{ dbt.type_string() }})  as customer_day_key,

    sales_code,
    customer_key,
    cast(event_at_local as date)                                         as activity_date,
    login_seq,
    stint_seq,

    event_at_utc,
    event_at_local,

    row_number() over (
        partition by sales_code, customer_key, cast(event_at_local as date)
        order by event_at_utc, entity_id
    )                                                                    as event_seq,

    -- dwell on the PREVIOUS step. Null on the first event of a login: the gap
    -- before it is idle time, not work on this customer.
    case
        when is_new_login = 1 then null
        else {{ dbt.datediff('prev_at', 'event_at_utc', 'second') }}
    end                                                                  as seconds_since_prev_event,

    device,
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
