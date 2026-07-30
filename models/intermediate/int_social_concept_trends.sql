{{ config(tags=['social']) }}
-- int_social_concept_trends — the trending-PRODUCT leaderboard, one row per
-- (period_grain, period_start, concept). DETERMINISTIC and LLM-free: it ranks the
-- SPECIFIC-PRODUCT signal on social signal only (volume x momentum x engagement).
-- No WMS key is touched — concept->SKU resolution is a separate offline LLM step.
--
-- WHAT COUNTS AS A TRENDING ITEM (learned from the real data, 2026-07-30):
--   * mentioned_dishes ONLY — the specific dish / product the AI pulled from the
--     content (e.g. "euro cake", "หมูกระจก", "banh mi", "som tam"). This is the
--     clean, specific-product signal.
--   * ingredients are NOT ranked — a bare "pork"/"lemon" token is a building
--     block, not the trending thing (it's why the first cut floated generic
--     tokens to the top). They feed the BASKET side in resolution instead.
--   * brands are NOT ranked either — the brands array is dominated by CHANNELS
--     people buy/post through (7-Eleven, Grab, LINE MAN), influencers/reviewers
--     (peach eat laek, hwanjeab channel) and restaurants (The Pizza Company),
--     none of which are items to stock, and they're unbounded so no exclusion
--     list catches them. The LLM resolver still READS brand context from each
--     concept's mention snippets (so "what's trending AT 7-Eleven" surfaces via
--     the dishes people posted), it just doesn't rank brands as items. If a real
--     PRODUCT-brand signal is ever needed, tag brand_kind in enrichment and add
--     only product brands here (v2).
--
-- Grain: emitted at BOTH day and week; the reader filters. momentum = this
-- period's mentions / prior-N OBSERVED periods' avg, capped; a brand-new concept
-- gets the novelty factor. Cross-language duplicates (som tam / ส้มตำ) still rank
-- separately here — the LLM resolver canonicalises them downstream (returns a
-- canonical_label the mart displays); full re-aggregation by canonical is a v2.
--
-- Materialized as a table: it is the GATE scripts/resolve_trending_concepts.py
-- reads to pick which top-N concepts to resolve to SKUs.

with mentions as (

    select
        mention_id,
        posted_date,
        posted_week,
        coalesce(total_engagement, total_engagement_with_views, 0)      as engagement,
        sentiment_normalized,
        mentioned_dishes
    from {{ ref('fct_social_mentions') }}

),

-- explode the dish stream (the specific-product signal). ONE unnest per select.
concepts_raw as (

    select mention_id, posted_date, posted_week, engagement, sentiment_normalized,
           'dish' as concept_source, {{ unnest('mentioned_dishes') }} as concept
    from mentions

),

concepts as (

    select
        mention_id,
        posted_date,
        posted_week,
        engagement,
        sentiment_normalized,
        concept_source,
        lower(trim(concept))                                            as concept_norm
    from concepts_raw
    where nullif(trim(concept), '') is not null

),

-- fan the two grains out; carry mention-level facts through unchanged
periods as (

    select 'week' as period_grain, posted_week as period_start,
           concept_source, concept_norm, mention_id, engagement, sentiment_normalized
    from concepts

    union all
    select 'day'  as period_grain, posted_date as period_start,
           concept_source, concept_norm, mention_id, engagement, sentiment_normalized
    from concepts

),

-- one row per mention within a (grain, period, concept): a mention naming the
-- same concept as both a dish and a brand must not double-count its engagement
concept_mentions as (

    select distinct
        period_grain, period_start, concept_norm,
        mention_id, engagement, sentiment_normalized
    from periods

),

agg as (

    select
        period_grain,
        period_start,
        concept_norm,
        count(*)                                                        as mention_count,
        sum(engagement)                                                 as total_engagement,
        sum(case when sentiment_normalized = 'positive' then 1
                 when sentiment_normalized = 'negative' then -1
                 else 0 end)                                            as net_sentiment
    from concept_mentions
    group by 1, 2, 3

),

-- dominant source for the text (dish wins ties over brand: prefer the specific)
source_rank as (

    select
        period_grain, period_start, concept_norm, concept_source,
        row_number() over (
            partition by period_grain, period_start, concept_norm
            order by count(distinct mention_id) desc,
                     case when concept_source = 'dish' then 0 else 1 end
        )                                                               as _rn
    from periods
    group by 1, 2, 3, 4

),

dominant_source as (

    select period_grain, period_start, concept_norm, concept_source
    from source_rank
    where _rn = 1

),

scored as (

    select
        a.period_grain,
        a.period_start,
        a.concept_norm,
        d.concept_source,
        a.mention_count,
        a.total_engagement,
        a.net_sentiment,
        avg(a.mention_count) over (
            partition by a.period_grain, a.concept_norm
            order by a.period_start
            rows between {{ var('social_trend_lookback_periods') }} preceding and 1 preceding
        )                                                               as prior_avg_mentions
    from agg as a
    inner join dominant_source as d
        on  d.period_grain = a.period_grain
        and d.period_start = a.period_start
        and d.concept_norm = a.concept_norm

),

final as (

    select
        period_grain,
        period_start,
        concept_norm,
        concept_source,
        mention_count,
        total_engagement,
        net_sentiment,
        prior_avg_mentions,
        case
            when prior_avg_mentions is null
                then {{ var('social_trend_novelty_factor') }}
            else least(
                mention_count / nullif(prior_avg_mentions, 0),
                {{ var('social_trend_momentum_cap') }}
            )
        end                                                             as momentum
    from scored
    where mention_count >= {{ var('social_trend_min_mentions') }}

)

select
    period_grain,
    period_start,
    concept_norm,
    concept_source,
    mention_count,
    total_engagement,
    net_sentiment,
    prior_avg_mentions,
    momentum,
    mention_count
        * momentum
        * (1 + ln(1 + coalesce(total_engagement, 0)) / 10)              as trend_score,
    row_number() over (
        partition by period_grain, period_start
        order by
            mention_count
                * momentum
                * (1 + ln(1 + coalesce(total_engagement, 0)) / 10) desc,
            mention_count desc,
            concept_norm
    )                                                                   as trend_rank
from final
