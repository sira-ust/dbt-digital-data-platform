-- fct_order_cycles — one row per shopping cycle, reconstructed by time
-- heuristic. APPROXIMATE by design: cart events carry no order key (verified
-- 0/1,120,204 on the Databricks mirror 2026-07-08), so a cycle is inferred as:
--
--   burst  = a run of behavioural events for one customer with gaps under
--            var('cycle_gap_minutes') (60; decided 2026-07-08)
--   cycle  = a chain of bursts that ends at a SUBMIT event, or breaks after
--            var('cycle_abandon_days') (7) of inactivity
--
-- Behavioural events = cart edits (add/remove/qty), feature interactions
-- (search, filter, icons, catalog view, item detail, OOS checks) and submits.
-- Feature events count so that the search-before-first-add belongs to the
-- cycle it led to; a cycle with zero cart edits is a pure browsing session.
-- Events with no resolvable customer_key (18.5% of cart events on the real
-- mirror) cannot join any cycle and are excluded — surface that % next to any
-- cycle metric.
--
-- Two duration measures on purpose (overnight orders would otherwise inflate
-- a single naive duration): active_minutes sums time inside bursts only;
-- days_to_close is calendar time from first event to submit.
--
-- Full-rebuild table, NOT incremental: cycle boundaries shift as new events
-- arrive (an open cycle yesterday may close or merge today), so incremental
-- merge on cycle_id would strand stale rows.
--
-- When the app team stamps increment_id onto cart events, switch the cycle_seq
-- derivation to group by order number; every downstream mart keeps its contract.

with events as (

    select
        entity_id,
        customer_key,
        actor_type,
        sales_code,
        username,
        app_name,
        source_code,
        event_at_utc,
        is_add,
        is_remove,
        is_qty_change,
        feature_name,
        page_context,
        -- submit = server-side order receipt with a KV payload (04010100-
        -- 04040100) or the customer-app submit success (04050100, bare payload)
        (l1_code = '04'
            and (response like '%increment_id:%' or description_code = '04050100')
        )                                                                as is_submit,
        case
            when l1_code = '04' and response like '%increment_id:%'
                then {{ parse_kv_response('response', 'increment_id') }}
        end                                                              as submit_increment_id,
        -- cart payload is positional "sku,qty[,category]"
        case
            when is_add or is_remove or is_qty_change
                then {{ response_part('response', 1) }}
        end                                                              as cart_sku
    from {{ ref('int_events_enriched') }}
    where customer_key is not null
      and event_at_utc is not null
      and (
            is_add or is_remove or is_qty_change
            or feature_name is not null
            or (l1_code = '04'
                and (response like '%increment_id:%' or description_code = '04050100'))
          )

),

sequenced as (

    select
        *,
        lag(event_at_utc) over (
            partition by customer_key order by event_at_utc, entity_id
        )                                                                as prev_at,
        coalesce(lag(is_submit) over (
            partition by customer_key order by event_at_utc, entity_id
        ), false)                                                        as prev_was_submit
    from events

),

flagged as (

    select
        *,
        case
            when prev_at is null then 1
            when {{ dbt.datediff('prev_at', 'event_at_utc', 'minute') }}
                 >= {{ var('cycle_gap_minutes') }} then 1
            else 0
        end                                                              as is_new_burst,
        case
            when prev_at is null then 1
            when prev_was_submit then 1
            when {{ dbt.datediff('prev_at', 'event_at_utc', 'minute') }}
                 >= {{ var('cycle_abandon_days') }} * 24 * 60 then 1
            else 0
        end                                                              as is_new_cycle
    from sequenced

),

numbered as (

    select
        *,
        sum(is_new_cycle) over (
            partition by customer_key
            order by event_at_utc, entity_id
            rows between unbounded preceding and current row
        )                                                                as cycle_seq,
        sum(is_new_burst) over (
            partition by customer_key
            order by event_at_utc, entity_id
            rows between unbounded preceding and current row
        )                                                                as burst_seq
    from flagged

),

-- active time = sum of within-burst spans; a single-event burst contributes 0
bursts as (

    select
        customer_key,
        cycle_seq,
        burst_seq,
        {{ dbt.datediff('min(event_at_utc)', 'max(event_at_utc)', 'minute') }}
                                                                         as burst_minutes
    from numbered
    group by customer_key, cycle_seq, burst_seq

),

burst_rollup as (

    select
        customer_key,
        cycle_seq,
        count(*)                                                         as burst_count,
        sum(burst_minutes)                                               as active_minutes
    from bursts
    group by customer_key, cycle_seq

),

-- dominant app = the source with the most events in the cycle
app_ranked as (

    select
        customer_key,
        cycle_seq,
        app_name,
        source_code,
        row_number() over (
            partition by customer_key, cycle_seq
            order by count(*) desc, app_name
        )                                                                as _rn
    from numbered
    group by customer_key, cycle_seq, app_name, source_code

),

cycles as (

    select
        customer_key,
        cycle_seq,
        min(event_at_utc)                                                as started_at_utc,
        max(event_at_utc)                                                as ended_at_utc,
        count(*)                                                         as event_count,
        sum(case when is_add then 1 else 0 end)                          as add_count,
        sum(case when is_remove then 1 else 0 end)                       as remove_count,
        sum(case when is_qty_change then 1 else 0 end)                   as qty_change_count,
        count(distinct cart_sku)                                         as distinct_skus,
        count(distinct cast(event_at_utc as date))                       as days_active,
        -- action features
        sum(case when feature_name = 'search' then 1 else 0 end)         as search_count,
        sum(case when feature_name = 'filter' then 1 else 0 end)         as filter_count,
        sum(case when feature_name = 'icon_click' then 1 else 0 end)     as icon_click_count,
        sum(case when feature_name = 'catalog_view' then 1 else 0 end)   as catalog_view_count,
        sum(case when feature_name = 'item_detail' then 1 else 0 end)    as item_detail_count,
        sum(case when feature_name = 'oos_check' then 1 else 0 end)      as oos_check_count,
        count(distinct feature_name)                                     as features_used_count,
        -- catalog sections
        sum(case when page_context = 'promo' then 1 else 0 end)          as promo_count,
        sum(case when page_context = 'backorder' then 1 else 0 end)      as backorder_count,
        sum(case when page_context = 'history' then 1 else 0 end)        as history_count,
        sum(case when page_context = 'suggest' then 1 else 0 end)        as suggest_count,
        -- actors
        max(case when actor_type = 'sales' then 1 else 0 end)            as _has_sales,
        max(case when actor_type = 'sales' then sales_code end)          as sales_code,
        max(case when actor_type = 'sales' then username end)            as rep_username,
        -- close
        max(case when is_submit then 1 else 0 end)                       as _submitted,
        max(submit_increment_id)                                         as submit_increment_id,
        max(case when is_submit then event_at_utc end)                   as submitted_at_utc
    from numbered
    group by customer_key, cycle_seq

)

select
    c.customer_key || '-' || cast(c.cycle_seq as {{ dbt.type_string() }}) as cycle_id,
    c.customer_key,
    c.cycle_seq,
    c._has_sales = 1                                                     as is_sales_assisted,
    c.sales_code,
    c.rep_username,
    a.app_name,
    a.source_code,
    c.started_at_utc,
    c.ended_at_utc,
    cast(c.started_at_utc as date)                                       as started_date,
    b.burst_count,
    b.active_minutes,
    c.days_active,
    c.event_count,
    c.add_count,
    c.remove_count,
    c.qty_change_count,
    c.add_count - c.remove_count                                         as net_item_events,
    c.distinct_skus,
    c.search_count,
    c.filter_count,
    c.icon_click_count,
    c.catalog_view_count,
    c.item_detail_count,
    c.oos_check_count,
    c.promo_count,
    c.backorder_count,
    c.history_count,
    c.suggest_count,
    c.features_used_count,
    c._submitted = 1                                                     as is_submitted,
    c.submit_increment_id,
    c.submitted_at_utc,
    case
        when c._submitted = 1
            then {{ dbt.datediff('c.started_at_utc', 'c.submitted_at_utc', 'day') }}
    end                                                                  as days_to_close,
    case
        when c._submitted = 1 then 'submitted'
        when {{ dbt.datediff('c.ended_at_utc', dbt.current_timestamp(), 'day') }}
             >= {{ var('cycle_abandon_days') }} then 'abandoned'
        else 'open'
    end                                                                  as cycle_status,
    -- selling-style segment (proposed defaults, tune after review):
    --   churner       more removes than adds
    --   quick_reorder submitted with little/no browsing, one short sitting
    --   browser       wide feature usage before (or without) buying
    --   mixed         everything else
    case
        when c.remove_count > c.add_count                       then 'churner'
        when c._submitted = 1
             and c.features_used_count <= 1
             and coalesce(b.active_minutes, 0) <= 15            then 'quick_reorder'
        when c.features_used_count >= 3                         then 'browser'
        else 'mixed'
    end                                                                  as segment_name
from cycles as c
left join burst_rollup as b
    on b.customer_key = c.customer_key and b.cycle_seq = c.cycle_seq
left join app_ranked as a
    on a.customer_key = c.customer_key and a.cycle_seq = c.cycle_seq and a._rn = 1
