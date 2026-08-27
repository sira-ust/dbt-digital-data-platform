-- Which orders did the customer TEXT or EMAIL in, with the rep just keying them?
--
-- Nothing in the data records this. There is no inbound-message field anywhere:
-- system_event_log has 15 columns and none references an order or a quote, and
-- across 1,821,206 cart/browse events the `response` payload never carries an
-- increment_id, a quote id, or an M-order number (the 5 apparent hits are reps
-- typing an order number into the SEARCH box). Family 13 "Send Email / Fax" is
-- outbound invoices and statements only. So this is INFERRED from behaviour.
--
-- Two queries here, same engine:
--   Version A (active)        one row per order, indicators as measured values
--   Version B (commented out) rolled up per customer -- who does this HABITUALLY
--
-- == THE FIVE INDICATORS ===================================================
--   on_site_min          minutes of GPS fixes matched to that customer's store,
--                        within a 100 m geofence, that same day        [= 0]
--   one_shot_session     order built in ONE unbroken stretch; 30+ min idle
--                        would split it                               [= true]
--   median_sec_per_item  seconds between consecutive item adds     [<= 10, incl]
--   browse_per_item      browse events / items added, unitless        [< 0.25]
--   typed_share          adds on the line-item entry screen (10050900) over ALL
--                        adds (which include catalog clicks and history cart
--                        adds)                                        [>= 0.90]
--
-- BROWSE EVENT = the rep looked something up rather than keying a known item:
-- search, filter, catalog view, item detail, image enlarge, icon tap, OOS check.
-- Adds and submits are not browse events.
--
-- == THINGS TO KNOW BEFORE QUOTING A NUMBER ================================
--
-- gps_available IS REQUIRED. On days with no usable GPS (scenario 'unknown' --
-- customer has no coordinates, or no fixes logged) on_site_min reads 0 because
-- we cannot tell, NOT because he was away. Ignoring this inflated rep 028 from
-- 26 flagged orders to 45. Absence of evidence is not evidence of absence.
--
-- browse_per_item IS THE WEAKEST OF THE FIVE, because it is partly a device
-- proxy: for 028 the iPad browses 0.46 per add and the PDA only 0.13, and
-- catalog_view and filter never fire on the PDA at all. Both the passing and
-- failing groups are PDA-dominant (89% vs 74%) while their browse rates differ
-- 10x, so real behaviour drives most of the gap -- but discount this indicator.
-- typed_share is the strongest: it measures a choice WITHIN one device.
--
-- SINGLE-ORDER DAYS ONLY. increment_id exists only on the submit event and is
-- never back-filled onto the adds before it, so on a 2-order day there is no
-- way to know which adds fed which order. Excluded rather than guessed.
-- Rep 028, trailing 6 months: 408 orders -> 112 on multi-order days -> 296 on
-- single-order days -> 129 of those logged NO cart adds at all (a submit with
-- no preceding cart activity is legitimate and common) -> 47 had 1-9 items ->
-- 120 measurable -> 26 flagged. So a flag count is a FLOOR, not a total.
--
-- DEDUPED INLINE. The PDA re-sends batches it already sent and each pass inserts
-- fresh entity_ids, so 21.4% of the event spine is duplicate rows. Left in, item
-- counts inflate 1.2-1.9x per customer and median_sec_per_item collapses to 0
-- (two of every three gaps become 0). Computed from int_events_enriched rather
-- than mart_rep_customer_activity_events because the mart does not carry
-- `response`, and the payload is part of the dedupe key. Remove the dup_rn
-- filter once int_events_decoded carries the fix.
--
-- WHAT IT CANNOT TELL YOU: that the order arrived by text or email specifically.
-- It shows the order was received REMOTELY and keyed from something external --
-- a phone call, or a list handed over on a previous visit, looks identical.
--
-- Change the rep by editing the sales_code filter in `deduped` AND `day_totals`.

with deduped as (

    select *
    from (
        select
            e.*,
            row_number() over (
                partition by e.sales_code, e.customer_key, e.event_at_utc,
                             e.description_code, e.response
                order by e.entity_id
            ) as dup_rn
        from ust_databricks.ust_intermediate.int_events_enriched as e
        where e.sales_code   = '028'
          and e.actor_type   = 'sales'
          and e.customer_key is not null
          and e.rep_local_date >= add_months(current_date(), -6)
          -- same work-event filter as int_rep_customer_activity
          and (e.is_add or e.is_remove or e.is_qty_change
               or e.feature_name is not null
               or e.l1_code in ('04', '09'))
    ) as x
    where dup_rn = 1

),

-- session islands: a gap of 30+ min (var activity_gap_minutes) starts a new one
gapped as (

    select
        *,
        case when unix_timestamp(event_at_utc) - unix_timestamp(
                     lag(event_at_utc) over (partition by customer_key, rep_local_date
                                             order by event_at_utc)) >= 1800
                  or lag(event_at_utc) over (partition by customer_key, rep_local_date
                                             order by event_at_utc) is null
             then 1 else 0 end                                            as is_new_session,
        case when is_add then unix_timestamp(event_at_utc) - unix_timestamp(
                     lag(case when is_add then event_at_utc end) ignore nulls over (
                         partition by customer_key, rep_local_date order by event_at_utc))
        end                                                               as sec_since_prev_add
    from deduped

),

per_day as (

    select
        customer_key,
        rep_local_date                                                    as order_date,
        max(case when l1_code = '04' and response like '%increment_id:%'
                 then regexp_extract(response, 'increment_id:([^,]*)', 1) end) as order_no,
        sum(is_new_session)                                               as sessions,
        sum(case when is_add then 1 else 0 end)                           as items,
        sum(case when feature_name is not null then 1 else 0 end)         as browse_events,
        sum(case when description_code = '10050900' then 1 else 0 end)    as typed_adds,
        percentile_approx(sec_since_prev_add, 0.5)                        as median_sec_per_item
    from gapped
    group by 1, 2

),

day_totals as (

    -- the mart is one row per day PER SCENARIO; collapse it or the join fans out
    select
        customer_key,
        activity_date,
        sum(orders_submitted)                                             as orders_submitted,
        max(coalesce(on_site_minutes, 0))                                 as on_site_minutes,
        max(case when scenario = 'unknown' then 0 else 1 end)             as gps_available
    from ust_databricks.ust_reporting.mart_rep_customer_activity
    where sales_code = '028'
    group by 1, 2

),

scored as (

    select
        p.order_date,
        p.customer_key                                    as customer,
        p.order_no,
        p.items,
        t.on_site_minutes                                 as on_site_min,
        p.sessions = 1                                    as one_shot_session,
        p.median_sec_per_item,
        round(try_divide(p.browse_events, p.items), 2)    as browse_per_item,
        round(try_divide(p.typed_adds,    p.items), 2)    as typed_share,
        t.gps_available = 1                               as gps_available,
        (    t.gps_available     = 1
         and t.on_site_minutes   = 0
         and p.sessions          = 1
         and p.median_sec_per_item <= 10  -- inclusive: 4 of 028's 26 sit exactly at 10
         and try_divide(p.browse_events, p.items) <  0.25
         and try_divide(p.typed_adds,    p.items) >= 0.90 ) as likely_texted
    from per_day as p
    join day_totals as t
        on t.customer_key  = p.customer_key
       and t.activity_date = p.order_date
    where t.orders_submitted = 1     -- one order per row; see header
      and p.items >= 10              -- too few to judge below this

)

-- == Version A: one row per order ==========================================
select *
from scored
order by likely_texted desc, order_date desc


-- == Version B: rolled up per customer -- who does this HABITUALLY? =========
-- Read pct_texted WITH orders: 100% off a single order is one observation, not
-- a pattern. A customer appearing 2+ times is the real signal.
--
-- select
--     customer,
--     count(*)                                                       as orders,
--     sum(case when likely_texted then 1 else 0 end)                 as texted_orders,
--     round(100.0 * sum(case when likely_texted then 1 else 0 end)
--                 / count(*), 0)                                     as pct_texted,
--     round(avg(items), 0)                                           as avg_items,
--     round(avg(median_sec_per_item), 1)                             as sec_per_item,
--     round(avg(browse_per_item), 2)                                 as browse_per_item,
--     round(avg(typed_share), 2)                                     as typed_share
-- from scored
-- group by customer
-- having sum(case when likely_texted then 1 else 0 end) > 0
-- order by texted_orders desc, pct_texted desc
