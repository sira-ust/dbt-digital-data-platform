{{ config(tags=['promo']) }}
-- int_promo_scraped_matches — the best verified YouTube videos per promo item and
-- month, at most var('promo_scraped_max_per_item') (3). Source = 'Scraped'.
--
-- VERIFIED = Exact by the same rule as social listening: the keyword pass found
-- brand + product (+ flavor) in the title / description / tags AND the judge
-- said exact. Scraped rows are Exact or nothing — a Close video is not worth a
-- row when the point of the search is to find the item itself.
--
-- RECENT FIRST: an item with any verified video posted within
-- var('promo_scraped_max_age_months') (24) before the promo month keeps only those.
-- An item with none falls back to its older videos (is_recent = false; the mart's
-- Match Note says so). Anchored on the promo month, not today, so a rerun gives the
-- same answer. The search has no date filter, so older videos are there to fall
-- back on at no extra quota.
--
-- RANKED BY PERFORMANCE: views first, then engagement (likes + comments). "1-3
-- depending on how many come back": an item with one verified video gets one row;
-- it is never padded with weaker matches.
--
-- Searching is gated upstream (youtube_search.py searches branded items with no
-- social-listening match, plus every own-brand item), and the mart enforces it
-- again, so a Scraped row sits next to a Social Listening row only for an own brand.

with videos as (

    select
        *,
        cast(published_at as date)
            >= {{ dbt.dateadd('month', -1 * var('promo_scraped_max_age_months'), 'promo_month') }}
            as is_recent
    from {{ ref('stg_promo__youtube_videos') }}
    where verdict = 'exact' and keyword_level = 'exact'

),

-- recent videos when the item has any, otherwise all of them
eligible as (

    select *
    from (
        select
            *,
            max(case when is_recent then 1 else 0 end)
                over (partition by promo_month, item_no) as _item_has_recent
        from videos
    ) as v
    where is_recent or _item_has_recent = 0

),

items as (

    select promo_month, promo_sheet, row_order, item_no
    from {{ ref('int_promo_items_enriched') }}

),

ranked as (

    select
        v.*,
        row_number() over (
            partition by v.promo_month, v.item_no
            order by v.view_count desc nulls last,
                     coalesce(v.like_count, 0) + coalesce(v.comment_count, 0) desc,
                     v.video_id
        ) as scraped_rank
    from eligible as v

)

select
    i.promo_month,
    i.promo_sheet,
    i.row_order,
    i.item_no,
    r.video_id,
    r.scraped_rank,
    'Exact'                                                      as match_status,
    r.matched_content_item,
    case when r.is_short then 'YouTube Shorts' else 'YouTube' end as channel,
    r.channel_title                                              as profile,
    cast(r.published_at as date)                                 as posted_on,
    r.view_count                                                 as views,
    r.like_count                                                 as likes,
    trim(concat_ws(' ', r.title, r.description))                 as caption,
    case
        when r.is_short then concat('https://www.youtube.com/shorts/', r.video_id)
        else concat('https://www.youtube.com/watch?v=', r.video_id)
    end                                                          as link,
    'Scraped'                                                    as source,
    r.reason                                                     as judge_reason,
    r.keyword_level,
    r.brand_hit,
    r.product_hit,
    r.flavor_hit,
    r.match_text,
    r.judge_model,
    r.search_query,
    r.searched_at,
    coalesce(r.is_recent, false)                                 as is_recent
from ranked as r
inner join items as i
    on i.item_no = r.item_no
   and i.promo_month = r.promo_month
where r.scraped_rank <= {{ var('promo_scraped_max_per_item') }}
