-- mart_feature_pairing — one row per feature pair x week: which features get
-- used together, and how usage trends week over week.
--
-- "Together" = the same customer used both features on the same DAY. The
-- system event log has no session id, so customer-day is the co-occurrence
-- window; the *ranking* of pairs is the signal, not the absolute counts.
--
-- Rows where feature_a = feature_b are the single-feature weekly trend
-- (co_occurrence_days = days the feature was used at all) — BI filters
-- feature_a = feature_b for trend charts, feature_a < feature_b for pairing.
-- Pairs are emitted once with feature_a < feature_b (alphabetical), never
-- mirrored. Features here are actions (feature_name); catalog sections
-- (promo/backorder/...) are covered in mart_customer_weekly.

with feature_days as (

    select distinct
        customer_key,
        cast(event_at_utc as date)                                       as event_date,
        cast({{ dbt.date_trunc('week', 'event_at_utc') }} as date)       as week_start,
        feature_name
    from {{ ref('int_events_enriched') }}
    where feature_name is not null
      and customer_key is not null
      and event_at_utc is not null

),

pairs as (

    select
        a.week_start,
        a.feature_name                                                   as feature_a,
        b.feature_name                                                   as feature_b,
        count(*)                                                         as co_occurrence_days,
        count(distinct a.customer_key)                                   as customers_count
    from feature_days as a
    join feature_days as b
        on b.customer_key = a.customer_key
        and b.event_date = a.event_date
        and b.feature_name >= a.feature_name
    group by 1, 2, 3

),

-- days each single feature was used, per week (denominator for pair strength)
feature_totals as (

    select
        week_start,
        feature_name,
        count(*)                                                         as feature_days
    from feature_days
    group by 1, 2

)

select
    p.week_start,
    p.feature_a,
    p.feature_b,
    p.co_occurrence_days,
    p.customers_count,
    cast(p.co_occurrence_days as double) / t.feature_days                as pct_of_a_days_with_b,
    p.co_occurrence_days - lag(p.co_occurrence_days) over (
        partition by p.feature_a, p.feature_b
        order by p.week_start
    )                                                                    as wow_change
from pairs as p
left join feature_totals as t
    on t.week_start = p.week_start and t.feature_name = p.feature_a
