{{ config(tags=['social']) }}
-- Consumption-facing social-listening fact — one row per mention, filtered to
-- food-relevant, non-spam mentions. This is the Genie / BI table; it relates to
-- WMS and mysql by shared dimensions (posted_week, market) and by AI/semantic
-- matching on themes/dishes at query time — never by a product foreign key.
--
-- Joins mentions to their LLM enrichment (LEFT JOIN, so not-yet-enriched rows
-- are visible here before the filter drops them) and adds conformed dimensions:
--   posted_date / posted_week  — the time axis (exact join to WMS weekly demand)
--   market                     — Thailand / Vietnam, from the tracker
-- and splits the overloaded followers_or_rank into channel-correct reach:
--   follower_count (social)    vs   domain_rank (Web / Alexa rank)
--
-- Filter: keep food-relevant mentions, and drop spam ONLY when the model is
-- confident (>= social_spam_confidence_min) so a shaky spam call doesn't hide a
-- real mention. Not-yet-enriched mentions (is_food_relevant is null) are excluded
-- until classified.
--
-- No separate intermediate model here on purpose: the join+dimension step had
-- exactly one consumer (this fact), unlike int_events_enriched (7 consumers) —
-- a single-consumer pass-through doesn't earn its own materialization. If a
-- second consumer of the unfiltered, enriched set ever shows up, split it back
-- out then.

with mentions as (

    select * from {{ ref('stg_mentionlytics__mentions') }}

),

enrichment as (

    select * from {{ ref('stg_mentionlytics__mention_enrichment') }}

),

enriched as (

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

        m.sentiment,                    -- raw Mentionlytics label (free, from the
                                        -- source; the LLM no longer judges sentiment)

        -- LLM attributes (null for not-yet-enriched mentions)
        e.is_food_relevant,
        e.is_spam,
        e.themes,
        e.mentioned_dishes,
        e.mentioned_products,
        e.ingredients,
        e.brands,
        e.confidence,
        e.enriched_at,
        e.model_version
    from mentions as m
    left join enrichment as e
        on e.mention_id = m.mention_id

)

select
    mention_id,

    -- conformed dimensions
    posted_at,
    posted_date,
    posted_week,
    market,

    channel,
    mention_category,
    profile,
    language,
    country,
    location,
    keyword,
    tracker,
    link,
    title,
    content,

    -- reach + engagement
    follower_count,
    domain_rank,
    likes,
    comments,
    shares,
    views,
    impressions,
    total_engagement,
    total_engagement_with_views,

    -- sentiment
    sentiment,

    -- LLM attributes
    is_food_relevant,
    is_spam,
    themes,
    mentioned_dishes,
    mentioned_products,
    ingredients,
    brands,
    confidence,
    enriched_at,
    model_version
from enriched
where is_food_relevant = true
  and not (coalesce(is_spam, false) and confidence >= {{ var('social_spam_confidence_min') }})
