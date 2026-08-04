-- Lossless 1:1 staging for Mentionlytics mentions. Light work only: cast, trim,
-- rename to analytics-friendly names, and dedupe. Every source field is
-- preserved. NO decoding, sentiment normalisation, or LLM enrichment here — that
-- lives in fct_social_mentions and the offline enrich_mentions.py step.
--
-- Rerunnable dedupe: a mention_id can appear in more than one weekly file
-- (overlapping export windows, or a re-drop). Partition by mention_id and keep
-- the row from the latest export (loaded_at desc, source_file desc as a
-- deterministic tiebreak) — so a later export's updated metrics (e.g. 10 → 20
-- likes) win, and an identical re-appearance collapses to one row.

with source as (

    select * from {{ source('mentionlytics', 'mentions') }}

),

typed as (

    select
        cast(id as bigint)                                                       as mention_id,
        nullif(trim(cast(channel   as {{ dbt.type_string() }})), '')             as channel,
        nullif(trim(cast(category  as {{ dbt.type_string() }})), '')             as mention_category,
        nullif(trim(cast(profile   as {{ dbt.type_string() }})), '')             as profile,
        try_cast(profile_visits_web_only as bigint)                             as profile_visits,
        try_cast(profile_users_web_only  as bigint)                             as profile_users,
        nullif(trim(cast(language  as {{ dbt.type_string() }})), '')             as language,
        try_cast(followers_rank              as bigint)                          as followers_or_rank,
        try_cast(total_engagement            as bigint)                          as total_engagement,
        try_cast(total_engagement_with_views as bigint)                          as total_engagement_with_views,
        try_cast(likes       as bigint)                                          as likes,
        try_cast(comments    as bigint)                                          as comments,
        try_cast(shares      as bigint)                                          as shares,
        try_cast(views       as bigint)                                          as views,
        try_cast(impressions as bigint)                                          as impressions,
        try_cast(date as timestamp)                                              as posted_at,
        nullif(trim(cast(sentiment as {{ dbt.type_string() }})), '')             as sentiment,
        nullif(trim(cast(title     as {{ dbt.type_string() }})), '')             as title,
        nullif(trim(cast(content   as {{ dbt.type_string() }})), '')             as content,
        nullif(trim(cast(country   as {{ dbt.type_string() }})), '')             as country,
        nullif(trim(cast(location  as {{ dbt.type_string() }})), '')             as location,
        nullif(trim(cast(tracker   as {{ dbt.type_string() }})), '')             as tracker,
        nullif(trim(cast(keyword   as {{ dbt.type_string() }})), '')             as keyword,
        nullif(trim(cast(link      as {{ dbt.type_string() }})), '')             as link,
        try_cast(loaded_at as timestamp)                                         as loaded_at,
        nullif(trim(cast(source_file as {{ dbt.type_string() }})), '')           as source_file
    from source

),

numbered as (

    -- latest export wins per mention_id (see header note)
    select
        *,
        row_number() over (
            partition by mention_id
            order by loaded_at desc, source_file desc
        ) as _rn
    from typed

)

select
    mention_id,
    channel,
    mention_category,
    profile,
    profile_visits,
    profile_users,
    language,
    followers_or_rank,
    total_engagement,
    total_engagement_with_views,
    likes,
    comments,
    shares,
    views,
    impressions,
    posted_at,
    sentiment,
    title,
    content,
    country,
    location,
    tracker,
    keyword,
    link,
    loaded_at,
    source_file
from numbered
where _rn = 1
