{{ config(tags=['social']) }}
-- Mentions joined to their LLM enrichment — one row per mention. Keeps ALL
-- mentions (LEFT JOIN enrichment) so dq_social_mentions can observe coverage /
-- spam / food-relevance off the full set; the spam/food FILTER is applied
-- downstream in fct_social_mentions, not here.
--
-- Adds conformed dimensions for correlating beside WMS without a product key:
--   posted_date / posted_week  — the time axis (exact join to WMS weekly demand)
--   market                     — Thailand / Vietnam, from the tracker
-- and splits the overloaded followers_or_rank into channel-correct reach:
--   follower_count (social)    vs   domain_rank (Web / Alexa rank)

with mentions as (

    select * from {{ ref('stg_mentionlytics__mentions') }}

),

enrichment as (

    select * from {{ ref('stg_mentionlytics__mention_enrichment') }}

)

select
    m.mention_id,

    -- time axis
    m.posted_at,
    cast(m.posted_at as date)                             as posted_date,
    cast(date_trunc('week', m.posted_at) as date)         as posted_week,

    -- market (conformed dimension for correlating with WMS / mysql)
    case
        when m.tracker ilike '%thai%'    then 'Thailand'
        when m.tracker ilike '%vietnam%' then 'Vietnam'
        else 'Other'
    end                                                   as market,

    m.channel,
    m.mention_category,
    m.profile,
    m.language,
    m.country,
    m.location,
    m.keyword,
    m.tracker,
    m.link,
    m.title,
    m.content,

    -- channel-correct reach (never sum across channels — the source column is overloaded)
    case when m.channel = 'Web' then null else m.followers_or_rank end as follower_count,
    case when m.channel = 'Web' then m.followers_or_rank else null end as domain_rank,

    m.likes,
    m.comments,
    m.shares,
    m.views,
    m.impressions,
    m.total_engagement,
    m.total_engagement_with_views,

    m.sentiment,                    -- raw Mentionlytics label
    e.sentiment_normalized,         -- model-judged

    -- LLM attributes (null for not-yet-enriched mentions)
    e.is_food_relevant,
    e.is_spam,
    e.themes,
    e.mentioned_dishes,
    e.ingredients,
    e.brands,
    e.confidence,
    e.enriched_at,
    e.model_version,
    (e.mention_id is not null)      as is_enriched
from mentions as m
left join enrichment as e
    on e.mention_id = m.mention_id
