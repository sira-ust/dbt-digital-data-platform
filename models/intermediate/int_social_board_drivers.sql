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
--     the social_words_baseline_weeks before — a word that was always there (chili in
--     fish-sauce recipes) describes the row, it does not explain this week. A row with
--     fewer than 5 earlier posts is new, so this test is skipped;
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
-- and this model only writes the line; it is compiled into mart_social_trending_items.
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

)

select
    st.week_start,
    st.concept_class,
    st.concept_norm,
    concat_ws(' · ',
        max(case when st.story_rank = 1 then st.story_text end),
        max(case when st.story_rank = 2 then st.story_text end))       as driven_by,
    max(wd.detail_text)                                                 as driven_by_detail
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
            max(case when detail_rank = 6 then detail end))            as detail_text
    from word_detail
    group by 1, 2, 3
) as wd
    on {{ _sw_on('wd', 'st', part) }}
group by 1, 2, 3
