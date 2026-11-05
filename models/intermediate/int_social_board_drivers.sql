{{ config(materialized='ephemeral', tags=['social']) }}
{% set part = ['week_start', 'concept_class', 'concept_norm'] %}
{% set base_weeks = var('social_words_baseline_weeks') %}
{% set str = dbt.type_string() %}
-- int_social_board_drivers — WHAT IS DRIVING A BOARD ROW: the "Driven by" line. One row
-- per (week, board row) that has one; a row with no clear driver has no row here.
--
--   Mama Instant Noodles    spring onion ต้นหอม + mama tom klong noodles (มาม่าต้มโคล้ง)
--                           — together in 12 of 25 posts               (2026-W43)
--   Blueberry Cheesecake    squishy cake (สกุชชี่เค้ก) + blueberry บลูเบอร์รี่
--   Soufflé                 — together in 10 of 11 posts   (it IS the squishy cake row)
--
-- WHY. The board labels a row by its product, and the product can hide the trend: in
-- 2026-W43 14 of the 25 "Mama Instant Noodles" posts were the WaiWai Quik tom-klong-with-
-- spring-onion trend, which never formed a row of its own (see int_social_post_words). Words
-- found inside the row's OWN posts say what the row is really about this week.
--
-- A DRIVER WORD, in the row's posts this week, is
--   * in at least social_driver_min_posts of them, from social_driver_min_accounts
--     accounts, and in at least social_driver_min_row_share of the row's posts;
--   * social_driver_min_lift times more common in the row than in the week overall
--     (otherwise it is just a common word);
--   * social_driver_min_row_growth times more common than in the row's own posts over
--     the social_words_baseline_weeks before — a word that was always there describes
--     the row, it does not explain this week. A row with fewer than 5 earlier posts is
--     new, so this test is skipped. A word that passed it in the last
--     social_driver_hold_weeks weeks still counts while it passes the rest: the trend
--     stopped growing, it did not stop (Mama's spring onion in 2026-W44: in 7 of 14
--     posts, the same half as the weeks before);
--   * not an everyday word: a usual share above social_rising_words_max_base_per_k per
--     1,000 of ALL posts over the baseline weeks, the Rising list's cut-off. Chili,
--     sauce and broth ride along with any dish (chili in fish-sauce recipes);
--   * not the row itself: not one of its spellings, not a piece of its MAIN spellings
--     (ส้ม is in ส้มตำ, มาม่า in มาม่าเกาหลี) and not already in its name. Minor spellings
--     do not count: the name step files variants under the parent (มาม่าต้นหอม is filed
--     as plain Mama), and a variant is exactly what this line must be free to show.
-- The strongest social_driver_candidates words, by n_posts * ln(week posts / word posts),
-- are merged into stories (macros/social_word_stories: one word written several ways is
-- one word; words riding on the same posts are one story) and the best
-- social_driver_story_count stories are shown.
--
-- THREE STEPS. int_social_driver_words picks each row's candidate words and their
-- spelling groups, int_social_driver_stories merges them into stories (both tables),
-- and this model only writes the line and picks the posts behind it (driver_links); it
-- is compiled into mart_social_trending_items.
-- As one query, the whole analysis was too big for Databricks to compile (2026-11-04).

with {{ social_driver_rows(base_weeks) }},

-- the word list (Latin or not, English name)
words as (

    select distinct term, is_latin, gloss
    from {{ ref('int_social_post_words') }}
    where term is not null

),

top_cands as (

    select week_start, concept_class, concept_norm, term, n_posts, n_before, score
    from {{ ref('int_social_driver_words') }}

),

drv_grp as (

    select week_start, concept_class, concept_norm, term, n_posts, grp
    from {{ ref('int_social_driver_words') }}

),

cand_hits as (

    select h.week_start, h.concept_class, h.concept_norm, h.term, h.mention_id as post_key
    from row_hits as h
    inner join top_cands as t
        on {{ _sw_on('t', 'h', part) }} and t.term = h.term
    where h.is_now

),

{{ social_word_group_hits('drv_grp', 'cand_hits', part, 'drv') }},

drv_story as (

    select * from {{ ref('int_social_driver_stories') }}

),

story_words as (

    select
        s.week_start,
        s.concept_class,
        s.concept_norm,
        s.story,
        count(*)                                                        as n_words,
        max(t.score)                                                    as story_score
    from drv_story as s
    inner join top_cands as t
        on {{ _sw_on('t', 's', part) }} and t.term = s.head
    group by 1, 2, 3, 4

),

-- posts carrying EVERY shown word of the story
story_together as (

    select g.week_start, g.concept_class, g.concept_norm, g.story, count(*) as together
    from (
        select s.week_start, s.concept_class, s.concept_norm, s.story, gh.post_key,
               count(distinct s.grp)                                    as words_in_post
        from drv_story as s
        inner join drv_grp_hits as gh
            on {{ _sw_on('gh', 's', part) }} and gh.grp = s.grp
        group by 1, 2, 3, 4, 5
    ) as g
    inner join story_words as sw
        on {{ _sw_on('sw', 'g', part) }} and sw.story = g.story
    where g.words_in_post = sw.n_words
    group by 1, 2, 3, 4

),

story_ranked as (

    select
        sw.*,
        coalesce(st.together, 0)                                        as together,
        row_number() over (
            partition by sw.week_start, sw.concept_class, sw.concept_norm
            order by sw.story_score desc, sw.story
        )                                                               as story_rank
    from story_words as sw
    left join story_together as st
        on {{ _sw_on('st', 'sw', part) }} and st.story = sw.story

),

-- the row's posts that carried the word in the baseline weeks before
word_before as (

    select s.week_start, s.concept_class, s.concept_norm, s.grp, count(distinct h.mention_id) as before_posts
    from drv_story as s
    inner join drv_grp as g
        on {{ _sw_on('g', 's', part) }} and g.grp = s.grp
    inner join row_hits as h
        on {{ _sw_on('h', 's', part) }} and h.term = g.term and not h.is_now
    group by 1, 2, 3, 4

),

shown as (

    select
        s.week_start,
        s.concept_class,
        s.concept_norm,
        sr.story_rank,
        sr.n_words,
        sr.together,
        s.head,
        s.grp_posts,
        s.also_written,
        coalesce(wb.before_posts, 0)                                    as before_posts,
        rs.row_posts,
        -- Latin words read as themselves; a Thai word gets its English name when the
        -- name step has one ("mama tom klong noodles (มาม่าต้มโคล้ง)")
        case when w.is_latin then s.head
             when w.gloss is not null then w.gloss || ' (' || s.head || ')'
             else s.head end                                            as word_label,
        row_number() over (
            partition by s.week_start, s.concept_class, s.concept_norm, s.story
            order by s.grp_posts desc, length(s.head) desc, s.head
        )                                                               as word_rank
    from drv_story as s
    inner join story_ranked as sr
        on {{ _sw_on('sr', 's', part) }} and sr.story = s.story
    inner join words as w
        on w.term = s.head
    inner join row_size as rs
        on {{ _sw_on('rs', 's', part) }}
    left join word_before as wb
        on {{ _sw_on('wb', 's', part) }} and wb.grp = s.grp
    where sr.story_rank <= {{ var('social_driver_story_count') }}

),

story_text as (

    select
        week_start,
        concept_class,
        concept_norm,
        story_rank,
        concat_ws(' + ',
            max(case when word_rank = 1 then word_label end),
            max(case when word_rank = 2 then word_label end),
            max(case when word_rank = 3 then word_label end))
        || case when max(n_words) > 3
                then ' +' || cast(max(n_words) - 3 as {{ str }}) || ' more' else '' end
        || ' — '
        || case when max(n_words) > 1
                then 'together in ' || cast(max(together) as {{ str }})
                else 'in ' || cast(max(grp_posts) as {{ str }}) end
        || ' of ' || cast(max(row_posts) as {{ str }}) || ' posts'     as story_text
    from shown
    group by 1, 2, 3, 4

),

word_detail as (

    select
        week_start,
        concept_class,
        concept_norm,
        word_label || ': ' || cast(grp_posts as {{ str }}) || ' of ' || cast(row_posts as {{ str }})
            || ' posts this week, ' || cast(before_posts as {{ str }})
            || ' in the {{ base_weeks }} weeks before'
            || case when also_written is not null then ' (also written ' || also_written || ')' else '' end
                                                                        as detail,
        row_number() over (
            partition by week_start, concept_class, concept_norm order by story_rank, word_rank
        )                                                               as detail_rank
    from shown

),

lines as (

    select
        st.week_start,
        st.concept_class,
        st.concept_norm,
        concat_ws(' · ',
            max(case when st.story_rank = 1 then st.story_text end),
            max(case when st.story_rank = 2 then st.story_text end))   as driven_by,
        max(wd.detail_text)                                             as driven_by_detail
    from story_text as st
    left join (
        select
            week_start,
            concept_class,
            concept_norm,
            concat_ws('; ',
                max(case when detail_rank = 1 then detail end),
                max(case when detail_rank = 2 then detail end),
                max(case when detail_rank = 3 then detail end),
                max(case when detail_rank = 4 then detail end),
                max(case when detail_rank = 5 then detail end),
                max(case when detail_rank = 6 then detail end))        as detail_text
        from word_detail
        group by 1, 2, 3
    ) as wd
        on {{ _sw_on('wd', 'st', part) }}
    group by 1, 2, 3

),

-- THE POSTS BEHIND THE LINE, as links a reader can open: the row's posts this week that
-- carry a shown word. Those carrying more of the shown words first, then the best
-- performers for their platform: engagement and views over that channel's typical
-- post that week, as the row's own links are ranked (int_social_concept_trends), so a
-- liked Instagram post is not sorted under a TikTok with a few views. A post nobody
-- engaged with or viewed is a link only when the row has nothing else. A YouTube
-- video's comments are one post, linked to the video. Without these the row's links are
-- its biggest posts on ANY subject: Mama's in 2026-W44 led with a pad kee mao video
-- while the line said spring onion.
post_links as (

    select
        pw.mention_id,
        max(pw.thread_key)                                              as thread_key,
        max(pw.link)                                                    as link
    from {{ ref('int_social_post_words') }} as pw
    where pw.link is not null
    group by 1

),

channel_week as (

    select
        cast(posted_week as date)                                       as week_start,
        channel,
        median(coalesce(likes, 0) + coalesce(comments, 0) + coalesce(shares, 0)) as median_engagement,
        median(coalesce(views, 0))                                      as median_views
    from {{ ref('fct_social_mentions') }}
    group by 1, 2

),

driver_posts as (

    select
        s.week_start,
        s.concept_class,
        s.concept_norm,
        p.thread_key,
        max(p.link)                                                     as link,
        count(distinct s.grp)                                           as words_in_post,
        max(coalesce(f.likes, 0) + coalesce(f.comments, 0) + coalesce(f.shares, 0)) as engagement,
        max(coalesce(f.views, 0))                                       as views,
        max((case when cw.median_engagement > 0
                  then (coalesce(f.likes, 0) + coalesce(f.comments, 0) + coalesce(f.shares, 0)) * 1.0
                       / cw.median_engagement
                  else 0 end)
          + (case when cw.median_views > 0 then coalesce(f.views, 0) * 1.0 / cw.median_views
                  else 0 end))                                          as reach
    from drv_story as s
    inner join story_ranked as sr
        on {{ _sw_on('sr', 's', part) }} and sr.story = s.story
    inner join drv_grp_hits as gh
        on {{ _sw_on('gh', 's', part) }} and gh.grp = s.grp
    inner join post_links as p
        on p.mention_id = gh.post_key
    inner join {{ ref('fct_social_mentions') }} as f
        on f.mention_id = gh.post_key
    left join channel_week as cw
        on cw.week_start = s.week_start and cw.channel = f.channel
    where sr.story_rank <= {{ var('social_driver_story_count') }}
    group by 1, 2, 3, 4

),

driver_links_ranked as (

    select
        d.*,
        row_number() over (
            partition by d.week_start, d.concept_class, d.concept_norm
            order by d.words_in_post desc, d.reach desc, d.engagement desc, d.link
        )                                                               as link_rank
    from (
        select
            *,
            max(case when engagement > 0 or views > 0 then 1 else 0 end) over (
                partition by week_start, concept_class, concept_norm
            )                                                           as has_live
        from driver_posts
    ) as d
    where d.engagement > 0 or d.views > 0 or d.has_live = 0

),

-- no `order by` inside array_agg (Databricks' collect_list has none): a top-N SET, as
-- int_social_concept_trends' source_links
driver_links as (

    select week_start, concept_class, concept_norm, array_agg(link) as driver_links
    from driver_links_ranked
    where link_rank <= {{ var('social_trend_link_count') }}
    group by 1, 2, 3

)

select
    l.week_start,
    l.concept_class,
    l.concept_norm,
    l.driven_by,
    l.driven_by_detail,
    dl.driver_links
from lines as l
left join driver_links as dl
    on {{ _sw_on('dl', 'l', part) }}
