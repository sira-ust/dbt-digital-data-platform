{{ config(tags=['social']) }}
-- Consumption-facing social-listening fact — one row per mention, filtered to
-- food-relevant, non-spam mentions. This is the Genie / BI table; it relates to
-- WMS and mysql by shared dimensions (posted_week, market) and by AI/semantic
-- matching on themes/dishes at query time — never by a product foreign key.
--
-- Filter: keep food-relevant mentions, and drop spam ONLY when the model is
-- confident (>= social_spam_confidence_min) so a shaky spam call doesn't hide a
-- real mention. Not-yet-enriched mentions (is_food_relevant is null) are excluded
-- until classified. The full, unfiltered set (incl. spam/non-food) stays in
-- int_social_mentions_enriched for dq_social_mentions to audit.

with enriched as (

    select * from {{ ref('int_social_mentions_enriched') }}

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
    sentiment_normalized,

    -- LLM attributes
    is_food_relevant,
    is_spam,
    themes,
    mentioned_dishes,
    ingredients,
    brands,
    confidence,
    enriched_at,
    model_version
from enriched
where is_food_relevant = true
  and not (coalesce(is_spam, false) and confidence >= {{ var('social_spam_confidence_min') }})
