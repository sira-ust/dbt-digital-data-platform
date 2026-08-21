{# one carry-forward window over each rep's timeline, reused below #}
{% set ble_window %}
    partition by sales_code order by event_at_utc, entity_id
    rows between unbounded preceding and current row
{% endset %}
-- All events enriched with the event dictionary (seed_event_codes) and the
-- app-source registry. Event grain — one row per log record.
--
-- Reads the decoded spine (int_events_decoded); decoding/parsing lives there,
-- this model only adds the dictionary + app-source joins and the dictionary-
-- driven classification columns:
--   outcome        success/fail parsed from the dev team's "- Success/- Fail"
--                  function names (the flip segment differs by family, so the
--                  name is the authoritative marker, not the code position)
--   feature_name   canonical product feature (search, filter, icon_click, ...)
--   feature_group  rollup: discovery / navigation / cart / stock
--   page_context   which catalog section the action happened in
--                  (promo / backorder / history / suggest)
--   is_add / is_remove / is_qty_change   cart-edit flags (10.05x/10.04x/10.15x)
--
-- All classification applies ONLY to dictionary-mapped codes: unmapped codes
-- (legacy app codes, scanner junk) get nulls and are surfaced separately in
-- dq_unmapped_event_codes. Aggregations belong in mart_* (not in intermediate).
--
-- customer_key is also REPAIRED here, because four downstream models filter on
-- it and every one of them was losing the same events.
--
-- BLE pairing an iPad (CatalogFS) to a PDA TRANSFERS the open cart to the PDA;
-- the devices do not mirror, the PDA just gains control of the iPad's catalog
-- screen (confirmed with the app dev, 2026-08-21). The iPad's own taps then
-- write into an order it no longer owns, so they arrive with NO ust_customer_no.
-- Measured 2026-08-01..19: a paired iPad lost 15,221 of 22,800 cart edits
-- (66.8%); an iPad that never paired lost ZERO of 17,519. Anything filtering
-- `customer_key is not null` silently dropped that work — int_rep_customer_activity
-- (fixed), fct_order_cycles (22,182 rows), mart_customer_weekly (64,955),
-- mart_feature_pairing (6,651).
--
-- So the customer is INHERITED, but ONLY when the event does not carry one:
--   1. the customer the app named when the pairing opened (17020301 carries it
--      on 597 of 635 events = 94%; 17010300 on 91 of 91)
--   2. else the customer the paired PDA had open, if recent enough
-- customer_key_source records which, so an inherited customer is never mistaken
-- for a declared one — filter to 'event' for anything that must be exact.
--
-- Restricted to CatalogFS: the PDA never loses customer_key on a cart edit
-- (0 of 39,597), so there is nothing to repair there and nothing to risk. And it
-- fills ONLY nulls, so a rep like 018 who pairs without an open cart to transfer
-- (93.5% of its paired events keep their own customer) needs no special case.
--
-- Pairing has NO reliable end event — ZERO Unpair (17020200) and ZERO Forget
-- Device (17030000) logged in August 2026 — so the window expires after
-- var('ble_pairing_expiry_minutes'); without that a single connect stayed
-- "paired" for 4,149 minutes.

with events as (

    select * from {{ ref('int_events_decoded') }}

),

codes as (

    select * from {{ ref('seed_event_codes') }}

),

apps as (

    select * from {{ ref('seed_app_sources') }}

),

system_accounts as (

    select username from {{ ref('seed_system_accounts') }}

),

-- ── BLE pairing state, over the rep's own timeline ────────────────────────
-- Scoped to sales actors: customer-app events have no sales_code, and
-- partitioning them all under one null key would be a needless full sort.
sales_timeline as (

    select
        entity_id,
        sales_code,
        customer_key,
        event_at_utc,
        source_code,
        description_code,
        device_name
    from events
    where actor_type   = 'sales'
      and sales_code   is not null
      and event_at_utc is not null

),

ble_marks as (

    select
        entity_id,
        sales_code,
        event_at_utc,
        -- pairing opens on Pair-Success / Auto Connection-Success
        case
            when description_code in ('17020101', '17020301')             then event_at_utc
        end                                                              as connect_at,
        case
            when description_code in ('17020101', '17020301', '17010300') then customer_key
        end                                                              as connect_customer,
        case
            when description_code in ('17020101', '17020301')             then device_name
        end                                                              as connect_pda,
        -- and closes on a timeout or a failed scan. Unpair / Forget Device are
        -- listed for completeness; neither has ever been observed in the log.
        case
            when description_code in
                 ('17010700', '17040502', '17020200', '17030000')        then event_at_utc
        end                                                              as unpair_at,
        -- the customer the PDA currently has open, for fallback inheritance
        case
            when source_code = 'PDA-A' and customer_key is not null       then event_at_utc
        end                                                              as pda_customer_at,
        case
            when source_code = 'PDA-A' and customer_key is not null       then customer_key
        end                                                              as pda_customer
    from sales_timeline

),

ble_carried as (

    select
        entity_id,
        event_at_utc,
        {{ carry_forward('connect_at',       ble_window) }}               as connect_at,
        {{ carry_forward('connect_customer', ble_window) }}               as connect_customer,
        {{ carry_forward('connect_pda',      ble_window) }}               as connect_pda,
        {{ carry_forward('unpair_at',        ble_window) }}               as unpair_at,
        {{ carry_forward('pda_customer_at',  ble_window) }}               as pda_customer_at,
        {{ carry_forward('pda_customer',     ble_window) }}               as pda_customer
    from ble_marks

),

-- ── ONE local clock per rep-day, for every downstream model ───────────────
-- This used to be computed independently in int_rep_customer_activity AND in
-- int_rep_customer_presence. Both took the MODAL device_timezone, but over
-- different event populations — presence over 01040100 location pings (which the
-- PDAs emit constantly), activity over work events (which the iPad dominates).
-- So the two picked DIFFERENT offsets on 33% of rep-days in August 2026, and the
-- on-site/off-site comparison between them straddled clocks an hour apart. Rep
-- 026 on 2026-08-17 read as a 59-minute JUN003 visit ending 11:15 while the GPS
-- fixes put him in the car park until 12:15. Presence said -5, activity said -4.
-- The presence model's comment claimed the two matched; nothing enforced it.
-- Computing it ONCE here makes that structural rather than a hope.
--
-- WHY MAX AND NOT MODAL. CONFIRMED WITH THE APP DEV, 2026-08-21: the Android app
-- reads getRawOffset(), which returns STANDARD time and excludes daylight saving,
-- so a PDA reports GMT-5 for an Ohio rep all year. iOS reports the current actual
-- offset, so the iPad correctly moves to GMT-4 for summer. Measured across the
-- 2026-03-08 DST boundary: 12 of 12 iPads shifted their offset by an hour, and
-- 0 of 30 PDAs did, across four PDA hardware models — systematic to the app, not
-- per-device setup. A PDA-side fix is expected in an upcoming release.
--
-- A device that misses DST reports an offset one hour FURTHER from UTC than the
-- truth, so among devices sitting in the same pocket the LARGEST plausible offset
-- is the correct one: -4 beats -5 in August, and in January both say -5 so max
-- still gives -5. Modal instead hands the answer to whichever device happened to
-- log more, which is how the two models came to disagree. Max also stays correct
-- once the PDA fix ships, including through the mixed-version rollout, so this
-- needs no revisiting then.
--
-- PDA-ONLY REP-DAYS, 47% of days since 2026-03-08: no DST-aware device to borrow
-- from, so the displayed clock runs an hour behind. Deliberately left as is — both
-- models read this same offset, so they stay consistent WITH EACH OTHER and every
-- visit/session comparison remains valid. Only the wall clock shown is wrong, and
-- no duration is affected. Do not fix this by special-casing the PDA.
--
-- Clamped to [-10, -4]: real values run -8..-4 (Hawaii through Eastern), and one
-- device reported GMT+8 in August, which is not a place any rep was.
--
-- KNOWN LIMIT, and the real weakness of any device-label rule: max assumes every
-- device is in the rep's pocket. A PDA left behind in another state wins the max
-- and drags the whole day with it — 51 of 303 rep-days show devices more than an
-- hour apart, which the DST bug alone cannot explain, and the error there can be
-- 2-4 hours. Only a location-derived timezone fixes that. Also: a rep who genuinely
-- crosses a timezone mid-day gets the
-- easternmost offset for the whole day. That is the same limitation the modal
-- version had, and durations are unaffected — every gap and dwell is computed on
-- event_at_utc, which is epoch-derived and needs no timezone at all.
-- Pass 1: provisional offset, keyed on the UTC date.
rep_day_tz_utc as (

    select
        sales_code,
        cast(event_at_utc as date)                                       as utc_date,
        max(offset_hours)                                                as offset_hours
    from (
        select
            sales_code,
            event_at_utc,
            {{ tz_offset_hours('device_timezone') }}                     as offset_hours
        from events
        where actor_type   = 'sales'
          and sales_code   is not null
          and event_at_utc is not null
    ) as reported
    where offset_hours between -10 and -4
    group by sales_code, cast(event_at_utc as date)

),

-- Pass 2: RE-KEY onto the rep's LOCAL date, which is the grain every consumer
-- actually groups by (activity_date, customer_day_key, week_start).
--
-- Pass 1 alone is not enough. A rep on Eastern time working until 8pm is already
-- past midnight UTC, so their evening lands on the NEXT UTC date and picks up
-- that date's offset — a different number from their own morning. Measured
-- 2026-08-21: 686 of 3,393 local rep-days carried TWO offsets that way, which is
-- what still broke the shared-clock invariant after pass 1 (128 of 1,631 rep-days
-- disagreed) even though both models were reading the same column.
--
-- RESIDUAL EDGE CASE, deliberately not chased: the local date here is computed
-- with the PROVISIONAL offset, so an event within an hour of local midnight can
-- be assigned to the neighbouring local day when the two passes differ. Max
-- means pass 2 >= pass 1, so the drift is at most one hour and only at the day
-- boundary. Fixing it properly needs a location-derived zone rather than a
-- device label, which is a separate piece of work.
rep_day_tz as (

    select
        sales_code,
        local_date,
        max(offset_hours)                                                as offset_hours
    from (
        select
            p.sales_code,
            cast({{ add_hours('e.event_at_utc', 'p.offset_hours') }} as date) as local_date,
            p.offset_hours
        from events as e
        join rep_day_tz_utc as p
            on p.sales_code = e.sales_code
           and p.utc_date   = cast(e.event_at_utc as date)
        where e.actor_type   = 'sales'
          and e.sales_code   is not null
          and e.event_at_utc is not null
    ) as spanned
    group by sales_code, local_date

),

ble_state as (

    select
        entity_id,
        connect_customer,
        connect_pda,
        pda_customer,
        -- paired = a connect with no later close, that has not yet expired
        (
            connect_at is not null
            and (unpair_at is null or unpair_at < connect_at)
            and {{ dbt.datediff('connect_at', 'event_at_utc', 'minute') }}
                <= {{ var('ble_pairing_expiry_minutes') }}
        )                                                                as is_ble_paired,
        (
            pda_customer is not null
            and {{ dbt.datediff('pda_customer_at', 'event_at_utc', 'minute') }}
                <= {{ var('ble_inherit_max_stale_minutes') }}
        )                                                                as pda_customer_fresh
    from ble_carried

)

select
    -- Columns listed explicitly rather than e.*, because customer_key is
    -- REPLACED below with the BLE-resolved value and there is no portable
    -- `* except` — the spelling differs between databricks and duckdb.
    e.entity_id,
    e.sales_code,
    e.username,
    e.ust_customer_no,
    e.device_name,
    e.source_code,
    e.app_version,
    e.description_code,
    e.l1_code,
    e.l2_code,
    e.l3_code,
    e.l4_code,
    e.event_at_utc,
    e.device_timezone,
    e.created_at_utc,
    e.updated_at_utc,
    e.event_id_at_utc,
    e.latitude,
    e.longitude,
    e.actor_type,
    e.response,

    -- ── customer, repaired where BLE pairing orphaned it (see header) ────
    coalesce(
        e.customer_key,
        case
            when e.source_code in ('CatalogFS-I', 'CatalogFS-A')
                 and b.is_ble_paired                    then b.connect_customer
        end,
        case
            when e.source_code in ('CatalogFS-I', 'CatalogFS-A')
                 and b.pda_customer_fresh               then b.pda_customer
        end
    )                                                                   as customer_key,
    case
        when e.customer_key is not null                                 then 'event'
        when e.source_code not in ('CatalogFS-I', 'CatalogFS-A')        then null
        when b.is_ble_paired
             and b.connect_customer is not null                         then 'ble_session'
        when b.pda_customer_fresh                                       then 'paired_pda'
    end                                                                 as customer_key_source,
    coalesce(b.is_ble_paired, false)                                    as is_ble_paired,
    b.connect_pda                                                       as ble_pda_device,

    -- ── the rep's own wall clock. ONE value per rep-day, shared by every
    --    consumer, so a visit and the session inside it can never be read
    --    against clocks an hour apart. Null for customer-app events, which have
    --    no rep and no use for rep-local time.
    t.offset_hours                                                      as rep_day_offset_hours,
    {{ add_hours('e.event_at_utc', 't.offset_hours') }}                 as event_at_local,
    -- The rep-day this event belongs to. PUBLISHED rather than left to each
    -- consumer to re-derive as cast(event_at_local as date): the offset is keyed
    -- on the local date computed from the PROVISIONAL offset, so re-deriving it
    -- from the final offset can land on the neighbouring day and hand one
    -- rep-day two offsets again. That is exactly what still broke the
    -- shared-clock invariant on 46 of 1,537 rep-days after the two-pass fix.
    -- Group by THIS, not by a locally recomputed date.
    t.local_date                                                        as rep_local_date,

    c.function_name,
    c.l1_category_name,
    c.payload_format                as expected_payload_format,
    c.has_geo                       as expects_geo,
    c.is_system_event,
    c.event_type,
    c.log_level,
    a.app_name,
    a.user_type as app_user_type,
    a.platform as app_platform,

    -- ── outcome: parsed from the dictionary name, mapped codes only ─────
    case
        when c.description_code is null then null
        when lower(c.function_name) like '%fail%'    then 'fail'
        when lower(c.function_name) like '%success%' then 'success'
    end                                                                 as outcome,

    -- ── cart-edit flags (order-ops family, positions 1-4) ───────────────
    (c.description_code is not null
        and substr(e.description_code, 1, 4) = '1005')                  as is_add,
    (c.description_code is not null
        and substr(e.description_code, 1, 4) = '1004')                  as is_remove,
    (c.description_code is not null
        and substr(e.description_code, 1, 4) = '1015')                  as is_qty_change,

    -- ── feature: the action type. OOS check is name-based (lives in two
    --    families); the rest map from the L1 family. icon_click is only the
    --    18-family codes that are actual icon taps. ──────────────────────
    case
        when c.description_code is null then null
        when lower(c.function_name) like '%oos%'     then 'oos_check'
        when e.l1_code = '12'                        then 'search'
        when e.l1_code = '11'                        then 'filter'
        when e.l1_code = '19'                        then 'catalog_view'
        when e.l1_code = '14'                        then 'item_detail'
        when e.l1_code = '15'                        then 'image_enlarge'
        when e.l1_code = '18'
            and lower(c.function_name) like '%icon%' then 'icon_click'
    end                                                                 as feature_name,

    -- ── page context: which catalog section, independent of the action.
    --    add_item_promo_page = cart add (flag) in the promo section. ─────
    case
        when c.description_code is null then null
        when lower(c.function_name) like '%backorder%' then 'backorder'
        when lower(c.function_name) like '%history%'   then 'history'
        when lower(c.function_name) like '%suggest%'   then 'suggest'
        when lower(c.function_name) like '%promo%'     then 'promo'
    end                                                                 as page_context,

    -- ── feature rollup ───────────────────────────────────────────────────
    case
        when c.description_code is null then null
        when substr(e.description_code, 1, 4) in ('1004', '1005', '1015')
            then 'cart'
        when lower(c.function_name) like '%oos%'
            then 'stock'
        when e.l1_code in ('11', '12', '19')
            or (e.l1_code = '18' and lower(c.function_name) like '%icon%')
            then 'discovery'
        when e.l1_code in ('14', '15')
            then 'navigation'
    end                                                                 as feature_group

from events as e
left join codes as c
    on e.description_code = c.description_code
left join apps as a
    on e.source_code = a.source_code
left join ble_state as b
    on b.entity_id = e.entity_id
left join rep_day_tz_utc as tp
    on tp.sales_code = e.sales_code
   and tp.utc_date   = cast(e.event_at_utc as date)
left join rep_day_tz as t
    on t.sales_code = e.sales_code
   and t.local_date = cast({{ add_hours('e.event_at_utc', 'tp.offset_hours') }} as date)

where e.sales_code not in ('000')
  and (e.username is null or e.username not in (select username from system_accounts))
  and e.event_at_utc is not null
