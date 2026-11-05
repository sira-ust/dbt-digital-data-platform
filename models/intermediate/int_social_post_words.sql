{{ config(tags=['social']) }}
{% set vocab_days = 7 * var('social_words_vocab_weeks') - 1 %}
-- int_social_post_words — THE WORDS IN THE POSTS: the one table behind the "Driven by"
-- line and the rising-words list. One row per (post, word of the word list it contains);
-- a post containing none of them keeps ONE row with term null, so every post of the
-- window is here and both features size each week from this table alone. Three steps:
--
-- 1. THE WORD LIST is our own tags, not a hand-made dictionary. The board counts a post
--    toward a product through the AI's tags, and one trend gets tagged many ways: the
--    WaiWai Quik tom-klong-with-spring-onion trend (Oct 2026) was written ~15 ways across
--    ~30 products, none big enough to rank, while every post that just said มาม่า landed
--    on "Mama Instant Noodles". Looking for the WORDS in the text counts the trend once,
--    however each post was tagged. The words: every dish, product and ingredient the
--    enrichment extracted over the last social_words_vocab_weeks, tagged in at least
--    social_words_vocab_min_posts posts. Brands are left out on purpose — that array is
--    mostly shops, delivery apps, channels and influencers (7-Eleven, LINE MAN, "Thookie
--    in USA Channel"), which would "rise" with every promotion. Every active row of
--    seed_social_generic_terms is dropped too, whatever its applies_to: a word too generic
--    to rank is too generic to drive a row ('words' rows exist for exactly this). ONE LIST
--    FOR EVERY WEEK, built from the latest weeks — like in_stock on the mart, it is about
--    today. gloss is the English name the name step (canonicalize_concepts.py) gave the
--    word when it is itself a dish or product name (ต้มโคล้ง -> "tom khlong soup");
--    ingredient-only words have none yet (ต้นหอม): the name step reads dish and product
--    names only.
--
-- 2. THE POSTS: every board week plus the social_words_baseline_weeks before the first
--    (the "usual" a week is compared with). Two judgements, made once for both features:
--      thread_key  a YouTube video's comment thread is ONE post. Mentionlytics returns each
--                  comment as a mention, so one recipe video with 21 comments (9 of them
--                  the creator's own replies) would otherwise read as 22 posts about ขนมอึ่ง.
--      owner       the account behind the post: a comment belongs to the video's channel
--                  (Mentionlytics puts the channel name in a comment's title); an
--                  anonymised Instagram row is its own unknown account, as on the board.
--
-- 3. THE MATCHING is on the post TEXT, never its tags: that is the whole point. Thai words
--    match anywhere — Thai is written without spaces, so ต้มโคล้ง inside
--    "มาม่าต้มโคล้งใส่ต้นหอม" is the word. Latin words must match as whole words
--    (macros/social_words.sql), or "tea" would be found in every "steak". A word inside a
--    longer word is counted for both (ต้มโคล้ง and มาม่าต้มโคล้ง in the same post):
--    social_word_stories merges spellings later, where it can see the counts.
--    A 3-CHARACTER INDEX, not every post against every word. A word can only be in a post
--    that contains the word's first three characters, so each post is cut into its
--    three-character pieces and joined to the words on that piece (an equality join), and
--    only those candidates are searched. Every word is at least three characters, so no
--    match is missed. The plain cross join — ~50k posts x ~2k words, searched pair by
--    pair — ran past 11 minutes on duckdb over one quarter of data.
--
-- KEEP IT A TABLE. Everything else behind the word features lives inside the models that
-- read it, and making this one ephemeral too was tried (2026-11): same results, but the
-- build went from ~37 s to ~7 min on duckdb, because the driver and rising logic read it
-- in many places and an inlined step re-runs at every one of them.

with weeks as (

    select min(week_start) as first_week, max(week_start) as latest_week
    from {{ ref('int_social_trend_board') }}

),

-- 1. THE WORD LIST ------------------------------------------------------------------

recent as (

    select f.mention_id, f.mentioned_dishes, f.mentioned_products, f.ingredients
    from {{ ref('fct_social_mentions') }} as f
    cross join weeks as wk
    where cast(f.posted_week as date)
          between cast({{ dbt.dateadd('day', -vocab_days, 'wk.latest_week') }} as date) and wk.latest_week

),

-- three arrays, one generator per select (macros/unnest.sql)
tags as (

    select mention_id, {{ unnest('mentioned_dishes') }} as tag from recent
    union all
    select mention_id, {{ unnest('mentioned_products') }} as tag from recent
    union all
    select mention_id, {{ unnest('ingredients') }} as tag from recent

),

tagged as (

    select mention_id, lower(trim(tag)) as term
    from tags
    where nullif(trim(tag), '') is not null

),

stoplist as (

    select distinct lower(trim(term)) as term
    from {{ ref('seed_social_generic_terms') }}
    where coalesce(is_active, true)

),

-- the English name the name step gave each spelling that is a dish or product name
names as (

    select
        lower(trim(cm.concept_text))                                    as term,
        cn.product_name,
        count(*)                                                        as uses
    from {{ ref('int_social_concept_mentions') }} as cm
    inner join {{ ref('int_social_concept_canon') }} as cn
        on  cn.concept_class = cm.concept_class
        and cn.concept_norm  = cm.concept_norm
    where cn.product_name is not null
    group by 1, 2

),

gloss as (

    select term, product_name as gloss
    from (
        select
            n.*,
            row_number() over (partition by term order by uses desc, product_name) as _rn
        from names as n
    ) as r
    where _rn = 1

),

word_list as (

    select t.term, count(distinct t.mention_id) as tagged_posts
    from tagged as t
    left join stoplist as s
        on s.term = t.term
    where s.term is null
      and length(t.term) >= 3
      -- a tag carrying the LLM's gloss in brackets is a sentence, not a word
      and not {{ regex_matches('t.term', '[()]') }}
      and not {{ regex_matches('t.term', '^[0-9 .,-]+$') }}
    group by t.term
    having count(distinct t.mention_id) >= {{ var('social_words_vocab_min_posts') }}

),

words as (

    select
        w.term,
        -- Latin words match as WHOLE words only ("tea" is not in "steak"); Thai has no
        -- spaces, so Thai words match anywhere in the text
        {{ regex_matches('w.term', '^[a-z0-9 &.-]+$') }}                      as is_latin,
        w.tagged_posts,
        g.gloss,
        substr(w.term, 1, 3)                                            as piece
    from word_list as w
    left join gloss as g
        on g.term = w.term

),

-- 2. THE POSTS ----------------------------------------------------------------------

posts as (

    select
        f.mention_id,
        cast(f.posted_week as date)                                     as week_start,
        f.market,
        -- a comment links to its video
        case when f.mention_category = 'Youtube Comments'
             then regexp_replace(f.link, '&lc=.*$', '')
             else f.link end                                            as link,
        coalesce(f.views, 0)                                            as views,
        case when f.mention_category = 'Youtube Comments' and {{ regex_matches('f.link', '[?&]v=') }}
             then concat('yt:', regexp_extract(f.link, '[?&]v=([^&]+)', 1))
             else cast(f.mention_id as {{ dbt.type_string() }}) end     as thread_key,
        case when f.profile = 'Instagram User'
             then concat('ig:', cast(f.mention_id as {{ dbt.type_string() }}))
             when f.mention_category = 'Youtube Comments'
             then lower(trim(coalesce(f.title, f.profile)))
             else lower(trim(f.profile)) end                            as owner,
        lower(concat_ws(' ', f.title, f.content))                       as post_text
    from {{ ref('fct_social_mentions') }} as f
    cross join weeks as wk
    where cast(f.posted_week as date)
          between cast({{ dbt.dateadd('day', -7 * var('social_words_baseline_weeks'), 'wk.first_week') }} as date)
              and wk.latest_week

),

-- 3. THE MATCHING -------------------------------------------------------------------

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

    select p.mention_id, c.term, p.week_start
    from candidates as c
    inner join posts as p
        on p.mention_id = c.mention_id
    where instr(p.post_text, c.term) > 0
      and (not c.is_latin or {{ whole_word_match('p.post_text', 'c.term') }})

),

-- BUILDING BLOCKS, not things. Thai has no spaces, so a short word that is part of
-- hundreds of other words is "found" everywhere: ต้ม (boil) is in ต้มยำ, ต้มโคล้ง, ต้มข่า...
-- It shows as a word in the text of 288 posts for every post the AI tagged with it,
-- while a real word sits at 1-15 (สกุชชี่ 10, ต้มโคล้ง 8). Over the same weeks the word
-- list was taken from, a word above social_words_max_text_per_tag is dropped.
building_blocks as (

    select m.term
    from matches as m
    inner join words as w
        on w.term = m.term
    cross join weeks as wk
    where m.week_start between
          cast({{ dbt.dateadd('day', -vocab_days, 'wk.latest_week') }} as date)
          and wk.latest_week
    group by m.term, w.tagged_posts
    having count(distinct m.mention_id) > {{ var('social_words_max_text_per_tag') }} * w.tagged_posts

),

found as (

    select m.mention_id, m.term
    from matches as m
    left join building_blocks as b
        on b.term = m.term
    where b.term is null

)

select
    p.mention_id,
    p.week_start,
    p.thread_key,
    p.owner,
    p.link,
    p.views,
    p.market,
    fd.term,
    w.is_latin,
    w.gloss
from posts as p
left join found as fd
    on fd.mention_id = p.mention_id
left join words as w
    on w.term = fd.term
