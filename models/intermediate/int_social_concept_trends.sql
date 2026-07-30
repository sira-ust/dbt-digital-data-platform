{{ config(tags=['social']) }}
-- int_social_concept_trends — the trending-PRODUCT leaderboard, one row per
-- (period_start, concept). WEEKLY only (period_start = Monday-start ISO week).
-- DETERMINISTIC and LLM-free: ranks the specific-product signal on social signal
-- only (volume x momentum x engagement), no WMS key touched.
--
-- WHAT COUNTS AS A TRENDING ITEM (learned from the real data, 2026-07-30):
--   * mentioned_dishes ONLY — the specific dish / product the AI pulled from the
--     content (e.g. "euro cake", "หมูกระจก", "banh mi", "som tam"). The clean,
--     specific-product signal.
--   * ingredients are NOT ranked — a bare "pork"/"lemon" token is a building
--     block, not the trending thing. They feed the BASKET side in resolution.
--   * brands are NOT ranked — the brands array is dominated by CHANNELS people
--     buy/post through (7-Eleven, Grab, LINE MAN), influencers (peach eat laek)
--     and restaurants (The Pizza Company), none stockable and unbounded. The LLM
--     resolver still reads brand context from each concept's mention snippets.
--
-- source_links: the top social_trend_link_count mention URLs behind the concept,
-- picked by reach (follower_count) then engagement — so a reader can jump to the
-- loudest posts driving the trend. (Array order is not guaranteed; it is the
-- top-N set.)
--
-- momentum = this week's mentions / prior-N OBSERVED weeks' avg, capped; a
-- brand-new concept gets the novelty factor. Cross-language dupes (som tam /
-- ส้มตำ) rank separately — the LLM resolver canonicalises them downstream.
--
-- Materialized as a table: it is the GATE scripts/resolve_trending_concepts.py
-- reads to pick which top-N concepts to resolve to SKUs.

with mentions as (

    select
        mention_id,
        posted_week,
        coalesce(total_engagement, total_engagement_with_views, 0)      as engagement,
        follower_count,
        link,
        sentiment_normalized,
        mentioned_dishes
    from {{ ref('fct_social_mentions') }}

),

-- explode the dish stream (the specific-product signal). ONE unnest per select.
concepts_raw as (

    select mention_id, posted_week, engagement, follower_count, link, sentiment_normalized,
           {{ unnest('mentioned_dishes') }}                             as concept
    from mentions

),

concepts as (

    select
        mention_id,
        posted_week                                                     as period_start,
        engagement,
        follower_count,
        link,
        sentiment_normalized,
        lower(trim(concept))                                            as concept_norm
    from concepts_raw
    where nullif(trim(concept), '') is not null

),

-- one row per mention within a (week, concept): a mention naming the same
-- concept twice must not double-count its engagement / links
concept_mentions as (

    select distinct
        period_start, concept_norm, mention_id,
        engagement, follower_count, link, sentiment_normalized
    from concepts

),

agg as (

    select
        period_start,
        concept_norm,
        count(*)                                                        as mention_count,
        sum(engagement)                                                 as total_engagement,
        sum(case when sentiment_normalized = 'positive' then 1
                 when sentiment_normalized = 'negative' then -1
                 else 0 end)                                            as net_sentiment
    from concept_mentions
    group by 1, 2

),

-- top-N source links per concept: highest reach first, then engagement
links_ranked as (

    select
        period_start,
        concept_norm,
        link,
        row_number() over (
            partition by period_start, concept_norm
            order by coalesce(follower_count, 0) desc,
                     coalesce(engagement, 0) desc,
                     mention_id
        )                                                               as _rn
    from concept_mentions
    where link is not null

),

links_agg as (

    select
        period_start,
        concept_norm,
        array_agg(link)                                                 as source_links
    from links_ranked
    where _rn <= {{ var('social_trend_link_count') }}
    group by 1, 2

),

scored as (

    select
        a.period_start,
        a.concept_norm,
        a.mention_count,
        a.total_engagement,
        a.net_sentiment,
        avg(a.mention_count) over (
            partition by a.concept_norm
            order by a.period_start
            rows between {{ var('social_trend_lookback_periods') }} preceding and 1 preceding
        )                                                               as prior_avg_mentions
    from agg as a

),

final as (

    select
        period_start,
        concept_norm,
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
    f.period_start,
    f.concept_norm,
    'dish'                                                              as concept_source,
    f.mention_count,
    f.total_engagement,
    f.net_sentiment,
    f.prior_avg_mentions,
    f.momentum,
    f.mention_count
        * f.momentum
        * (1 + ln(1 + coalesce(f.total_engagement, 0)) / 10)           as trend_score,
    la.source_links,
    row_number() over (
        partition by f.period_start
        order by
            f.mention_count
                * f.momentum
                * (1 + ln(1 + coalesce(f.total_engagement, 0)) / 10) desc,
            f.mention_count desc,
            f.concept_norm
    )                                                                   as trend_rank
from final as f
left join links_agg as la
    on  la.period_start = f.period_start
    and la.concept_norm = f.concept_norm
