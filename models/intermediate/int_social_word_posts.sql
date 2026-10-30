{{ config(tags=['social']) }}
-- int_social_word_posts — the posts the word features read, one row per mention: every
-- board week plus the social_words_baseline_weeks before the first one (the "usual" a
-- week is compared with). Two judgements are made here, once, for both features:
--
--   thread_key  a YouTube video's comment thread is ONE post. Mentionlytics returns each
--               comment as a mention, so one recipe video with 21 comments (9 of them the
--               creator's own replies) would otherwise read as 22 posts about ขนมอึ่ง.
--   owner       the account behind the post: a comment belongs to the video's channel
--               (Mentionlytics puts the channel name in a comment's title); an anonymised
--               Instagram row is its own unknown account, as on the board.
--
-- post_text is title + content, lower-cased, for int_social_post_words to search.

with weeks as (

    select min(week_start) as first_week, max(week_start) as latest_week
    from {{ ref('int_social_trend_board') }}

)

select
    f.mention_id,
    cast(f.posted_week as date)                                         as week_start,
    f.market,
    f.channel,
    f.mention_category,
    -- a comment links to its video
    case when f.mention_category = 'Youtube Comments'
         then regexp_replace(f.link, '&lc=.*$', '')
         else f.link end                                                as link,
    coalesce(f.views, 0)                                                as views,
    case when f.mention_category = 'Youtube Comments' and {{ regex_matches('f.link', '[?&]v=') }}
         then concat('yt:', regexp_extract(f.link, '[?&]v=([^&]+)', 1))
         else cast(f.mention_id as {{ dbt.type_string() }}) end         as thread_key,
    case when f.profile = 'Instagram User'
         then concat('ig:', cast(f.mention_id as {{ dbt.type_string() }}))
         when f.mention_category = 'Youtube Comments'
         then lower(trim(coalesce(f.title, f.profile)))
         else lower(trim(f.profile)) end                                as owner,
    lower(concat_ws(' ', f.title, f.content))                           as post_text
from {{ ref('fct_social_mentions') }} as f
cross join weeks as w
where cast(f.posted_week as date)
      between cast({{ dbt.dateadd('day', -7 * var('social_words_baseline_weeks'), 'w.first_week') }} as date)
          and w.latest_week
