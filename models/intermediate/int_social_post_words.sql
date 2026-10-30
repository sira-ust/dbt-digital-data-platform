{{ config(tags=['social']) }}
-- int_social_post_words — which words of int_social_words each post contains. One row
-- per (mention, word). The one expensive step of the word features, done ONCE here so
-- the driver line and the rising list both read a table.
--
-- Matching is on the post TEXT, never on its tags: that is the whole point (see
-- int_social_words). Thai words match anywhere — Thai is written without spaces, so
-- ต้มโคล้ง inside "มาม่าต้มโคล้งใส่ต้นหอม" is the word. Latin words must match as whole
-- words (macros/social_words.sql), or "tea" would be found in every "steak".
--
-- A 3-CHARACTER INDEX, not every post against every word. A word can only be in a post
-- that contains the word's first three characters, so each post is cut into its
-- three-character pieces and joined to the words on that piece (an equality join), and
-- only those candidates are searched. Every word is at least three characters
-- (int_social_words), so no match is missed. The plain cross join — ~50k posts x ~2k
-- words, searched pair by pair — ran past 11 minutes on duckdb over one quarter of data.
--
-- A word inside a longer word is counted for both (ต้มโคล้ง and มาม่าต้มโคล้ง in the same
-- post): social_word_stories merges spellings later, where it can see the counts.

with words as (

    select term, is_latin, substr(term, 1, 3) as piece
    from {{ ref('int_social_words') }}

),

posts as (

    select mention_id, week_start, thread_key, owner, post_text
    from {{ ref('int_social_word_posts') }}

),

-- every three-character piece of every post, once per post
pieces as (

    select distinct mention_id, substr(post_text, pos, 3) as piece
    from (
        select
            mention_id,
            post_text,
            {{ unnest(int_series('1', 'greatest(length(post_text) - 2, 1)')) }} as pos
        from posts
    ) as positions

),

candidates as (

    select k.mention_id, w.term, w.is_latin
    from pieces as k
    inner join words as w
        on w.piece = k.piece

),

matches as (

    select
        p.mention_id,
        c.term,
        p.week_start,
        p.thread_key,
        p.owner
    from candidates as c
    inner join posts as p
        on p.mention_id = c.mention_id
    where instr(p.post_text, c.term) > 0
      and (not c.is_latin or {{ whole_word_match('p.post_text', 'c.term') }})

),

latest as (

    select max(week_start) as latest_week
    from {{ ref('int_social_trend_board') }}

),

-- BUILDING BLOCKS, not things. Thai has no spaces, so a short word that is part of
-- hundreds of other words is "found" everywhere: ต้ม (boil) is in ต้มยำ, ต้มโคล้ง, ต้มข่า...
-- It shows as a word in the text of 288 posts for every post the AI tagged with it,
-- while a real word sits at 1-15 (สกุชชี่ 10, ต้มโคล้ง 8). Over the same weeks the word
-- list was taken from, a word above social_words_max_text_per_tag is dropped.
building_blocks as (

    select m.term
    from matches as m
    inner join {{ ref('int_social_words') }} as w
        on w.term = m.term
    cross join latest as l
    where m.week_start between
          cast({{ dbt.dateadd('day', -(7 * var('social_words_vocab_weeks') - 1), 'l.latest_week') }} as date)
          and l.latest_week
    group by m.term, w.tagged_posts
    having count(distinct m.mention_id) > {{ var('social_words_max_text_per_tag') }} * w.tagged_posts

)

select m.*
from matches as m
left join building_blocks as b
    on b.term = m.term
where b.term is null
