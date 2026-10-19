-- YouTube search results per promo item and month, typed. One row per
-- (promo_month, item_no, video_id): the same video can come back from several of an
-- item's queries, and the latest search wins (fresher view counts).
--
-- ONLY THE ITEM'S LATEST SEARCH COUNTS. The landing table only appends, and an item
-- is searched again when its terms are re-drafted — so its earlier search's videos,
-- classified against terms that no longer exist, would otherwise stay. Item 24211
-- (2026-11) kept an Exact from its 10-15 search after the 10-18 re-draft added flavor
-- terms, failing assert_promo_exact_has_terms. youtube_search.py stamps one
-- searched_at per item per search, and a search with no results still writes a
-- marker row, so a re-search that finds nothing correctly empties the item.

with source as (

    select * from {{ source('promo', 'youtube_videos') }}

),

typed as (

    select
        cast(promo_month as date)                                                 as promo_month,
        nullif(trim(cast(item_no as {{ dbt.type_string() }})), '')               as item_no,
        nullif(trim(cast(video_id as {{ dbt.type_string() }})), '')              as video_id,
        nullif(trim(cast(search_query as {{ dbt.type_string() }})), '')          as search_query,
        try_cast(query_rank as integer)                                           as query_rank,
        nullif(trim(cast(title as {{ dbt.type_string() }})), '')                 as title,
        nullif(trim(cast(description as {{ dbt.type_string() }})), '')           as description,
        nullif(trim(cast(tags as {{ dbt.type_string() }})), '')                  as tags,
        nullif(trim(cast(channel_title as {{ dbt.type_string() }})), '')         as channel_title,
        nullif(trim(cast(channel_id as {{ dbt.type_string() }})), '')            as channel_id,
        try_cast(published_at as timestamp)                                       as published_at,
        try_cast(view_count as bigint)                                            as view_count,
        try_cast(like_count as bigint)                                            as like_count,
        try_cast(comment_count as bigint)                                         as comment_count,
        nullif(trim(cast(duration as {{ dbt.type_string() }})), '')              as duration,
        lower(trim(cast(is_short as {{ dbt.type_string() }}))) = 'true'          as is_short,
        nullif(trim(cast(keyword_level as {{ dbt.type_string() }})), '')         as keyword_level,
        nullif(cast(brand_hit as {{ dbt.type_string() }}), '')                   as brand_hit,
        nullif(cast(product_hit as {{ dbt.type_string() }}), '')                 as product_hit,
        nullif(cast(flavor_hit as {{ dbt.type_string() }}), '')                  as flavor_hit,
        cast(match_text as {{ dbt.type_string() }})                              as match_text,
        lower(trim(cast(verdict as {{ dbt.type_string() }})))                    as verdict,
        nullif(trim(cast(judge_votes as {{ dbt.type_string() }})), '')           as judge_votes,
        nullif(trim(cast(matched_content_item as {{ dbt.type_string() }})), '')  as matched_content_item,
        nullif(trim(cast(reason as {{ dbt.type_string() }})), '')                as reason,
        nullif(trim(cast(judge_model as {{ dbt.type_string() }})), '')           as judge_model,
        nullif(trim(cast(judge_version as {{ dbt.type_string() }})), '')         as judge_version,
        try_cast(searched_at as timestamp)                                        as searched_at
    from source

),

-- before the video_id filter, so a marker row (no results) still counts as a search
latest_search as (

    select
        *,
        max(searched_at) over (partition by promo_month, item_no) as _latest_searched_at
    from typed
    where item_no is not null

),

numbered as (

    select
        *,
        row_number() over (
            partition by promo_month, item_no, video_id
            order by searched_at desc, query_rank
        ) as _rn
    from latest_search
    where video_id is not null
      and searched_at = _latest_searched_at

)

select
    promo_month, item_no, video_id, search_query, query_rank, title, description, tags,
    channel_title, channel_id, published_at, view_count, like_count, comment_count,
    duration, is_short, keyword_level, brand_hit, product_hit, flavor_hit, match_text,
    verdict, judge_votes, matched_content_item, reason, judge_model, judge_version, searched_at
from numbered
where _rn = 1
