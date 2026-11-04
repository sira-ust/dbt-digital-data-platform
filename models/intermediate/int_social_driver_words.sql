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
    inner join words as w
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
