{{ config(tags=['social']) }}
{% set part = ['week_start', 'concept_class', 'concept_norm'] %}
{% set base_weeks = var('social_words_baseline_weeks') %}
-- int_social_driver_words — step 1 of 3 of the "Driven by" line: each board row's
-- candidate DRIVER WORDS this week, with the spelling group each one belongs to. One row
-- per (week, board row, word). What makes a driver word is described in
-- int_social_board_drivers, which writes the line; int_social_driver_stories (step 2)
-- merges these words into stories.
--
-- WHY A TABLE. Built as one query, the driver line reused its own steps so many times
-- that Databricks could not finish compiling it (2026-11-04). Saved here and in
-- int_social_driver_stories, every query stays small; the rows are the same.

with {{ social_driver_rows(base_weeks) }},

-- every post (to size the week) and the word list (Latin or not, English name)
posts as (

    select distinct mention_id, week_start
    from {{ ref('int_social_post_words') }}

),

words as (

    select distinct term, is_latin, gloss
    from {{ ref('int_social_post_words') }}
    where term is not null

),

-- how big the week is, and how common each word is across all of it
week_size as (

    select week_start, count(*) as week_posts
    from posts
    group by 1

),

word_week as (

    select week_start, term, count(*) as week_word_posts
    from hits
    group by 1, 2

),

-- how common each word USUALLY is across all posts, over the baseline weeks before. An
-- everyday word (chili, sauce, broth) rides along with any dish, so it never drives a
-- row: the same cut-off as the Rising list.
base_size as (

    select wk.week_start, sum(ws.week_posts) as base_posts
    from week_size as wk
    inner join week_size as ws
        on ws.week_start between cast({{ dbt.dateadd('day', -7 * base_weeks, 'wk.week_start') }} as date)
                             and cast({{ dbt.dateadd('day', -7, 'wk.week_start') }} as date)
    group by 1

),

word_base as (

    select wk.week_start, ww.term, sum(ww.week_word_posts) as base_word_posts
    from week_size as wk
    inner join word_week as ww
        on ww.week_start between cast({{ dbt.dateadd('day', -7 * base_weeks, 'wk.week_start') }} as date)
                             and cast({{ dbt.dateadd('day', -7, 'wk.week_start') }} as date)
    group by 1, 2

),

-- the spellings that ARE a product, and its MAIN ones (20%+ of its tags)
spellings as (

    select concept_norm, term, count(*) as uses
    from post_products
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
        c.n_posts * ln(ws.week_posts * 1.0 / ww.week_word_posts)        as score,
        -- it GREW inside the row (a new row has nothing to grow from)
        (rs.row_before < 5
         or (c.n_posts * 1.0 / rs.row_posts) / ((c.n_before + 0.5) / (rs.row_before + 0.5))
            >= {{ var('social_driver_min_row_growth') }})                as has_grown
    from cands as c
    inner join board as b
        on {{ _sw_on('b', 'c', part) }}
    inner join row_size as rs
        on {{ _sw_on('rs', 'c', part) }}
    inner join week_size as ws
        on ws.week_start = c.week_start
    inner join word_week as ww
        on ww.week_start = c.week_start and ww.term = c.term
    inner join words as w
        on w.term = c.term
    left join own_spelling as os
        on {{ _sw_on('os', 'c', part) }} and os.term = c.term
    left join name_piece as np
        on {{ _sw_on('np', 'c', part) }} and np.term = c.term
    left join base_size as bs
        on bs.week_start = c.week_start
    left join word_base as wb
        on wb.week_start = c.week_start and wb.term = c.term
    where os.term is null
      and np.term is null
      and c.n_posts >= {{ var('social_driver_min_posts') }}
      and c.n_accounts >= {{ var('social_driver_min_accounts') }}
      and c.n_posts >= {{ var('social_driver_min_row_share') }} * rs.row_posts
      -- already in the row's name
      and instr(b.row_name, c.term) = 0
      and (w.gloss is null or instr(b.row_name, lower(w.gloss)) = 0)
      -- not an everyday word
      and coalesce(1000.0 * wb.base_word_posts / nullif(bs.base_posts, 0), 0)
          <= {{ var('social_rising_words_max_base_per_k') }}

),

-- a word that grew inside the row in the last social_driver_hold_weeks weeks keeps
-- driving it while it still passes every other test: the trend stopped growing, it did
-- not stop. 2026-W44: Mama's spring onion was in 7 of 14 posts, the same half as the
-- weeks before, so the growth test alone hid why the row was #1.
held as (

    select
        *,
        -- the last earlier week the word grew inside this row (a window, not a self-join:
        -- a second read of `scored` would double what Databricks has to compile)
        max(case when has_grown and lift >= {{ var('social_driver_min_lift') }} then week_start end) over (
            partition by concept_class, concept_norm, term
            order by week_start
            rows between unbounded preceding and 1 preceding
        )                                                               as last_grown_week
    from scored

),

top_cands as (

    select week_start, concept_class, concept_norm, term, n_posts, n_before, score
    from held
    where lift >= {{ var('social_driver_min_lift') }}
      and (has_grown
           or last_grown_week >= cast({{ dbt.dateadd('day', -7 * var('social_driver_hold_weeks'), 'week_start') }} as date))
    qualify row_number() over (
        partition by week_start, concept_class, concept_norm order by score desc, term
    ) <= {{ var('social_driver_candidates') }}

),

{{ social_word_groups('top_cands', part, 'drv') }}

select
    t.week_start,
    t.concept_class,
    t.concept_norm,
    t.term,
    t.n_posts,
    t.n_before,
    t.score,
    g.grp
from top_cands as t
inner join drv_grp as g
    on {{ _sw_on('g', 't', part) }} and g.term = t.term
