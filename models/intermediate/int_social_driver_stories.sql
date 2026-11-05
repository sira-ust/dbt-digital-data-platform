{{ config(tags=['social']) }}
{% set part = ['week_start', 'concept_class', 'concept_norm'] %}
{% set base_weeks = var('social_words_baseline_weeks') %}
-- int_social_driver_stories — step 2 of 3 of the "Driven by" line: each board row's
-- driver words (int_social_driver_words) merged into STORIES — words written several
-- ways are one word, words riding on the same posts are one story (macros/social_words.sql).
-- One row per (week, board row, word group) shown in a story. int_social_board_drivers
-- writes the line from these rows.
--
-- WHY A TABLE: see int_social_driver_words.

with {{ social_driver_rows(base_weeks) }},

-- the candidate words with their spelling group, exactly the columns the macro reads
drv_groups as (

    select week_start, concept_class, concept_norm, term, n_posts, grp
    from {{ ref('int_social_driver_words') }}

),

-- the row's posts this week that carry each candidate word
cand_hits as (

    select h.week_start, h.concept_class, h.concept_norm, h.term, h.mention_id as post_key
    from row_hits as h
    inner join drv_groups as t
        on {{ _sw_on('t', 'h', part) }} and t.term = h.term
    where h.is_now

),

{{ social_word_stories('drv_groups', 'cand_hits', part, 'drv', var('social_driver_story_overlap')) }}

select
    week_start,
    concept_class,
    concept_norm,
    grp,
    head,
    grp_posts,
    story,
    also_written
from drv_story
