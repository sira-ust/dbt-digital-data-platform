{{ config(materialized='table') }}

-- mart_order_journey — Page 1 order journey, at order-cycle grain (one row per
-- increment_id x customer). Exact lifecycle from fct_order_cycle:
--   * days_to_close + close_bucket  -> days-to-close distribution
--   * is_pending + days_pending + pending_priority  -> pending orders (H/M/L)
--   * behavior_segment  -> Decisive / Planner / Slow Sender (from days in cycle)
--
-- Deferred refinements (need per-cycle edit counts, which require add-event
-- linkage — see DEFERRED-MODELS.md): the "High Editor" segment and add-count
-- weighting of pending priority. Store-type cuts need NAV. Empty on the current
-- extract (no Group 04/09 events); populates automatically when they arrive.

with cycles as (

    select * from {{ ref('fct_order_cycle') }}

)

select
    increment_id,
    customer_key,
    actor_type,
    source_code,
    app_name,
    sales_code,
    opened_at,
    submitted_at,
    is_submitted,
    days_to_close,

    -- pending = opened a cycle but never submitted
    (not is_submitted)                                                 as is_pending,
    case
        when not is_submitted and opened_at is not null
            then {{ dbt.datediff('opened_at', dbt.current_timestamp(), 'day') }}
    end                                                                as days_pending,

    -- close-speed bucket for the days-to-close distribution
    case
        when not is_submitted          then null
        when days_to_close <= 0        then 'Same day'
        when days_to_close <= 3        then '1-3 days'
        when days_to_close <= 7        then '4-7 days'
        when days_to_close <= 13       then '8-13 days'
        else                                '14+ days'
    end                                                                as close_bucket,

    -- behaviour segment from days in cycle (High Editor needs edit counts — deferred)
    case
        when not is_submitted          then null
        when days_to_close <= 0        then 'Decisive'
        when days_to_close <= 3        then 'Planner'
        else                                'Slow Sender'
    end                                                                as behavior_segment,

    -- pending priority by days pending (add-count weighting deferred)
    case
        when is_submitted or opened_at is null then null
        when {{ dbt.datediff('opened_at', dbt.current_timestamp(), 'day') }} >= 14 then 'H'
        when {{ dbt.datediff('opened_at', dbt.current_timestamp(), 'day') }} >= 7  then 'M'
        else 'L'
    end                                                                as pending_priority
from cycles
