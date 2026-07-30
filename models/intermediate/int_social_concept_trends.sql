{{ config(tags=['social']) }}
{% set window_days = 7 * var('social_trend_window_weeks') %}
{% set half_days = (window_days / 2) | int %}
-- int_social_concept_trends — "currently trending" snapshot, one row per concept.
-- DETERMINISTIC and LLM-free. NOT per-week: it aggregates ALL mentions in a
-- TRAILING WINDOW of social_trend_window_weeks ending at the latest data
-- (window_end = max posted_date), so a dish talked about for weeks keeps ranking
-- until its mentions age out of the window — that is what "currently trending"
-- means. Recomputed and replaced every run.
--
-- VOLUME-forward ranking: trend_score = window mentions x engagement, so
-- sustained-popular items (pho, banh mi) sit on top and the board is stable.
-- is_rising is a SECONDARY flag (recent half of the window vs the older half),
-- surfaced for context — it does NOT drive the sort.
--
-- The trending UNIT is mentioned_dishes only (the AI's specific-product signal);
-- ingredients (too generic) and brands (channels/influencers/restaurants) are not
-- ranked. Cross-language dupes (som tam / ส้มตำ) rank separately — the LLM
-- resolver canonicalises them downstream. source_links carries the top mention
-- URLs behind the concept (by reach then engagement).
--
-- Materialized as a table: it is the GATE scripts/resolve_trending_concepts.py
-- reads to pick which top-N concepts to resolve to SKUs.

with mentions as (

    select
        mention_id,
        cast(posted_date as date)                                       as posted_date,
        coalesce(total_engagement, total_engagement_with_views, 0)      as engagement,
        follower_count,
        link,
        sentiment_normalized,
        mentioned_dishes
    from {{ ref('fct_social_mentions') }}

),

bounds as (

    select max(posted_date) as window_end from mentions

),

scoped as (

    select
        m.*,
        b.window_end,
        cast({{ dbt.dateadd('day', -1 * (window_days - 1), 'b.window_end') }} as date) as window_start,
        cast({{ dbt.dateadd('day', -1 * half_days, 'b.window_end') }} as date)         as recent_cutoff
    from mentions as m
    cross join bounds as b

),

in_window as (

    select * from scoped where posted_date >= window_start

),

-- explode the dish stream (the specific-product signal). ONE unnest per select.
concepts_raw as (

    select
        mention_id, posted_date, engagement, follower_count, link, sentiment_normalized,
        window_start, window_end, recent_cutoff,
        {{ unnest('mentioned_dishes') }}                                as concept
    from in_window

),

concepts as (

    select
        mention_id, posted_date, engagement, follower_count, link, sentiment_normalized,
        window_start, window_end, recent_cutoff,
        -- fold Vietnamese diacritic/case/spacing variants to one key so the same
        -- dish (bánh khọt / banh khot) ranks once, not several times
        {{ fold_concept('concept') }}                                   as concept_norm
    from concepts_raw
    where nullif(trim(concept), '') is not null

),

-- one row per mention within a concept (a mention naming it twice counts once)
concept_mentions as (

    select distinct
        concept_norm, mention_id, posted_date,
        engagement, follower_count, link, sentiment_normalized,
        window_start, window_end, recent_cutoff
    from concepts

),

agg as (

    select
        concept_norm,
        max(window_start)                                              as window_start,
        max(window_end)                                                as window_end,
        count(*)                                                       as mention_count,
        sum(engagement)                                                as total_engagement,
        sum(case when sentiment_normalized = 'positive' then 1
                 when sentiment_normalized = 'negative' then -1
                 else 0 end)                                           as net_sentiment,
        sum(case when posted_date >  recent_cutoff then 1 else 0 end)  as recent_mentions,
        sum(case when posted_date <= recent_cutoff then 1 else 0 end)  as prior_mentions
    from concept_mentions
    group by 1

),

-- top-N source links per concept: highest reach first, then engagement
links_ranked as (

    select
        concept_norm,
        link,
        row_number() over (
            partition by concept_norm
            order by coalesce(follower_count, 0) desc,
                     coalesce(engagement, 0) desc,
                     mention_id
        )                                                              as _rn
    from concept_mentions
    where link is not null

),

links_agg as (

    select concept_norm, array_agg(link) as source_links
    from links_ranked
    where _rn <= {{ var('social_trend_link_count') }}
    group by 1

),

final as (

    select *
    from agg
    where mention_count >= {{ var('social_trend_min_mentions') }}

)

select
    f.concept_norm,
    'dish'                                                             as concept_source,
    f.window_start,
    f.window_end,
    f.mention_count,
    f.total_engagement,
    f.net_sentiment,
    f.recent_mentions,
    f.prior_mentions,
    f.recent_mentions > f.prior_mentions                              as is_rising,
    f.mention_count
        * (1 + ln(1 + coalesce(f.total_engagement, 0)) / 10)          as trend_score,
    la.source_links,
    row_number() over (
        order by
            f.mention_count
                * (1 + ln(1 + coalesce(f.total_engagement, 0)) / 10) desc,
            f.mention_count desc,
            f.concept_norm
    )                                                                  as trend_rank
from final as f
left join links_agg as la
    on la.concept_norm = f.concept_norm
