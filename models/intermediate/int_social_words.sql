{{ config(tags=['social']) }}
{% set vocab_days = 7 * var('social_words_vocab_weeks') - 1 %}
-- int_social_words — THE WORD LIST the "Driven by" line and the rising-words list look
-- for inside post text. One row per word.
--
-- WHY WORDS AND NOT TAGS. The board counts a post toward a product through the AI's
-- tags, and one trend gets tagged many ways: the WaiWai Quik tom-klong-with-spring-onion
-- trend (Oct 2026) was written ~15 ways across ~30 products, none big enough to rank,
-- while every post that just said มาม่า landed on "Mama Instant Noodles". Looking for the
-- WORDS in the text counts the trend once, however each post was tagged.
--
-- THE WORDS ARE OUR OWN TAGS, not a hand-made dictionary: every dish, product and
-- ingredient the enrichment extracted over the last social_words_vocab_weeks, tagged in
-- at least social_words_vocab_min_posts posts. Brands are left out on purpose — that
-- array is mostly shops, delivery apps, channels and influencers (7-Eleven, LINE MAN,
-- "Thookie in USA Channel"), which would "rise" with every promotion. Every active row
-- of seed_social_generic_terms is dropped too, whatever its applies_to: a word too
-- generic to rank is too generic to drive a row ('words' rows exist for exactly this).
--
-- ONE LIST FOR EVERY WEEK, built from the latest weeks — like in_stock on the mart, it
-- is about today. A week ranked before a word existed simply has no posts with it.
--
-- gloss is the English name the name step (canonicalize_concepts.py) gave the word when
-- the word is itself a dish or product name, e.g. ต้มโคล้ง -> "tom khlong soup".
-- Ingredient-only words have none yet (ต้นหอม): the name step only reads dish and
-- product names.

with latest as (

    select max(week_start) as latest_week
    from {{ ref('int_social_trend_board') }}

),

recent as (

    select f.mention_id, f.mentioned_dishes, f.mentioned_products, f.ingredients
    from {{ ref('fct_social_mentions') }} as f
    cross join latest as l
    where cast(f.posted_week as date)
          between cast({{ dbt.dateadd('day', -vocab_days, 'l.latest_week') }} as date) and l.latest_week

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

words as (

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

)

select
    w.term,
    -- Latin words match as WHOLE words only ("tea" is not in "steak"); Thai has no
    -- spaces, so Thai words match anywhere in the text
    {{ regex_matches('w.term', '^[a-z0-9 &.-]+$') }}                      as is_latin,
    w.tagged_posts,
    g.gloss
from words as w
left join gloss as g
    on g.term = w.term
