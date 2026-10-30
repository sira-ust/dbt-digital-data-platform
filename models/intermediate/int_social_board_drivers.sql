{{ config(tags=['social']) }}
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
-- spring-onion trend, which never formed a row of its own (see int_social_words). Words
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

with board as (

    select
        week_start,
        concept_class,
        concept_norm,
        lower(coalesce(product_name, concept_norm))                     as row_name
    from {{ ref('int_social_trend_board') }}
    where is_on_board

),

-- each board row's posts: this week (is_now) and the baseline weeks before it, mapped
-- exactly as the board maps them (int_social_post_products)
row_posts as (

    select distinct
        b.week_start,
        b.concept_class,
        b.concept_norm,
        pp.mention_id,
        pp.week_start = b.week_start                                    as is_now
    from board as b
    inner join {{ ref('int_social_post_products') }} as pp
        on  pp.concept_class = b.concept_class
        and pp.concept_norm  = b.concept_norm
        and pp.week_start between cast({{ dbt.dateadd('day', -7 * base_weeks, 'b.week_start') }} as date)
                              and b.week_start

),

row_size as (

    select
        week_start,
        concept_class,
        concept_norm,
        count(distinct case when is_now then mention_id end)            as row_posts,
        count(distinct case when not is_now then mention_id end)        as row_before
    from row_posts
    group by 1, 2, 3

),

row_hits as (

    select rp.week_start, rp.concept_class, rp.concept_norm, rp.is_now, pw.term, pw.mention_id, pw.owner
    from row_posts as rp
    inner join {{ ref('int_social_post_words') }} as pw
        on pw.mention_id = rp.mention_id

),

-- how big the week is, and how common each word is across all of it
week_size as (

    select week_start, count(*) as week_posts
    from {{ ref('int_social_word_posts') }}
    group by 1

),

word_week as (

    select week_start, term, count(*) as week_word_posts
    from {{ ref('int_social_post_words') }}
    group by 1, 2

),

-- the spellings that ARE a product, and its MAIN ones (20%+ of its tags)
spellings as (

    select concept_norm, term, count(*) as uses
    from {{ ref('int_social_post_products') }}
    group by 1, 2

),

main_spellings as (

    select s.concept_norm, s.term
    from spellings as s
    inner join (select concept_norm, max(uses) as top_uses from spellings group by 1) as m
        on m.concept_norm = s.concept_norm
    where s.uses >= 0.2 * m.top_uses

),

cands as (

    select
        h.week_start,
        h.concept_class,
        h.concept_norm,
        h.term,
        count(distinct case when h.is_now then h.mention_id end)        as n_posts,
        count(distinct case when h.is_now then h.owner end)             as n_accounts,
        count(distinct case when not h.is_now then h.mention_id end)    as n_before
    from row_hits as h
    group by 1, 2, 3, 4

),

own_spelling as (

    select distinct c.week_start, c.concept_class, c.concept_norm, c.term
    from cands as c
    inner join spellings as s
        on s.concept_norm = c.concept_norm and s.term = c.term

),

name_piece as (

    select distinct c.week_start, c.concept_class, c.concept_norm, c.term
    from cands as c
    inner join main_spellings as ms
        on ms.concept_norm = c.concept_norm and instr(ms.term, c.term) > 0

),

scored as (

    select
        c.*,
        (c.n_posts * 1.0 / rs.row_posts) / (ww.week_word_posts * 1.0 / ws.week_posts) as lift,
        c.n_posts * ln(ws.week_posts * 1.0 / ww.week_word_posts)        as score
    from cands as c
    inner join board as b
        on {{ _sw_on('b', 'c', part) }}
    inner join row_size as rs
        on {{ _sw_on('rs', 'c', part) }}
    inner join week_size as ws
        on ws.week_start = c.week_start
    inner join word_week as ww
        on ww.week_start = c.week_start and ww.term = c.term
    inner join {{ ref('int_social_words') }} as w
        on w.term = c.term
    left join own_spelling as os
        on {{ _sw_on('os', 'c', part) }} and os.term = c.term
    left join name_piece as np
        on {{ _sw_on('np', 'c', part) }} and np.term = c.term
    where os.term is null
      and np.term is null
      and c.n_posts >= {{ var('social_driver_min_posts') }}
      and c.n_accounts >= {{ var('social_driver_min_accounts') }}
      and c.n_posts >= {{ var('social_driver_min_row_share') }} * rs.row_posts
      -- already in the row's name
      and instr(b.row_name, c.term) = 0
      and (w.gloss is null or instr(b.row_name, lower(w.gloss)) = 0)
      -- it must have GROWN inside the row (a new row has nothing to grow from)
      and (rs.row_before < 5
           or (c.n_posts * 1.0 / rs.row_posts) / ((c.n_before + 0.5) / (rs.row_before + 0.5))
              >= {{ var('social_driver_min_row_growth') }})

),

top_cands as (

    select week_start, concept_class, concept_norm, term, n_posts, n_before, score
    from scored
    where lift >= {{ var('social_driver_min_lift') }}
    qualify row_number() over (
        partition by week_start, concept_class, concept_norm order by score desc, term
    ) <= {{ var('social_driver_candidates') }}

),

cand_hits as (

    select h.week_start, h.concept_class, h.concept_norm, h.term, h.mention_id as post_key
    from row_hits as h
    inner join top_cands as t
        on {{ _sw_on('t', 'h', part) }} and t.term = h.term
    where h.is_now

),

{{ social_word_stories('top_cands', 'cand_hits', part, 'drv', var('social_driver_story_overlap')) }},

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
    inner join {{ ref('int_social_words') }} as w
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
