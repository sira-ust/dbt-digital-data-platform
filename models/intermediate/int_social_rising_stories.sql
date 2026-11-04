{{ config(tags=['social']) }}
-- int_social_rising_stories — step 2 of 3 of the rising-words list: each week's rising
-- words (int_social_rising_word_groups) merged into STORIES — words written several ways
-- are one word, words riding on the same posts are one story (macros/social_words.sql).
-- One row per (week, word group) shown in a story. mart_social_rising_words builds the
-- list from these rows.
--
-- WHY A TABLE: see int_social_rising_word_groups.

with hits as (

    select week_start, term, thread_key
    from {{ ref('int_social_post_words') }}
    where term is not null

),

-- the candidate words with their spelling group, exactly the columns the macro reads
rw_groups as (

    select week_start, term, n_posts, grp
    from {{ ref('int_social_rising_word_groups') }}

),

-- a YouTube comment thread is one post
cand_hits as (

    select distinct pw.week_start, pw.term, pw.thread_key as post_key
    from hits as pw
    inner join rw_groups as c
        on c.week_start = pw.week_start and c.term = pw.term

),

{{ social_word_stories('rw_groups', 'cand_hits', ['week_start'], 'rw', var('social_rising_words_story_overlap')) }}

select
    week_start,
    grp,
    head,
    grp_posts,
    story,
    also_written
from rw_story
