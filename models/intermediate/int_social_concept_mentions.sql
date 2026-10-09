{{ config(tags=['social']) }}
-- int_social_concept_mentions — one row per (mention, class, concept): every dish and
-- product name a post's enrichment named, cleaned to the key the trending board ranks
-- on. ALL HISTORY, no week or retention logic: a name means the same thing whichever
-- week it was posted in.
--
-- Pulled out of int_social_concept_trends unchanged (2026-10), for two consumers that
-- need the names but not the weekly ranking:
--   * scripts/canonicalize_concepts.py, which maps every name ever extracted to one
--     canonical product ("ไอติมเลย์", "lays ice cream" -> lay's ice cream). It must see
--     all history, not the board's 13 retained weeks, because promo matching reads
--     all history too;
--   * int_social_concept_trends itself, which joins these rows to its week-scoped,
--     channel-normalised mentions by mention_id. One cleaning implementation, two
--     readers — the board and the name map can never disagree about what a name is.
--
-- Grain: NOT unique. A post naming the same thing twice (or two spellings that fold to
-- one key) yields two rows, exactly as the unnest always did; the board's
-- `select distinct` in concept_mentions is what collapses them, and it is kept there.

with mentions as (

    select
        mention_id,
        mentioned_dishes,
        mentioned_products,
        -- v4 enrichment: what the post is ABOUT, strict subsets of the two arrays
        -- above. NULL for any mention still labelled at v3 — see role_rank below.
        subject_dishes,
        subject_products
    from {{ ref('fct_social_mentions') }}

),

-- The two class streams. macros/unnest.sql allows exactly ONE generator per
-- SELECT on both engines, so each array gets its own select and they are UNION
-- ALLed. `union all`, never `union`: a mention naming the same string as both a
-- dish and an ingredient must keep both rows — the classes are separate rank
-- spaces. Both branches list the same columns in the same order because UNION ALL
-- matches by position, hence no `select *` inside them.
dish_concepts_raw as (

    select
        mention_id,
        'dish'                                                          as concept_class,
        -- the subject array for THIS class. A dish is a subject only if it is in
        -- subject_dishes; a product only if it is in subject_products. Crossing them
        -- would make every recipe's dish mark its ingredients as subjects too.
        subject_dishes                                                  as subject_arr,
        {{ unnest('mentioned_dishes') }}                                as concept
    from mentions

),

item_concepts_raw as (

    select
        mention_id,
        'item'                                                          as concept_class,
        subject_products                                                as subject_arr,
        {{ unnest('mentioned_products') }}                              as concept
    from mentions

),

concepts_raw as (

    select * from dish_concepts_raw
    union all
    select * from item_concepts_raw

),

-- strip a trailing LLM-appended gloss ("ขนมโตเกียว (tokyo pastry/snack)" ->
-- "ขนมโตเกียว") BEFORE folding. Kept as its own step so the empty-string edge
-- case (a concept that's entirely parenthetical) can fall back to the
-- original text instead of silently disappearing.
concepts_degloss as (

    select
        mention_id,
        concept_class,
        concept,
        -- ROLE: is this post ABOUT the concept, or does it merely name it?
        --   2 = subject     the post exists because of this thing
        --   1 = ingredient  named as a step, an ingredient, or one line on a menu
        --   0 = unknown     mention not yet re-labelled at prompt v4
        -- Decided on the RAW string, before deglossing and folding, because that is
        -- the spelling enrich_mentions._subset guarantees the subject array holds.
        -- Comparing after folding would need the same fold applied to the array and
        -- would silently return "not a subject" if the two ever drifted.
        --
        -- Three states, not a boolean: between deploying this model and finishing
        -- the v4 re-label the corpus is a mix, and treating an unlabelled mention as
        -- "not a subject" would report almost the whole board as incidental.
        case
            when subject_arr is null                        then 0
            when {{ array_contains('subject_arr', 'concept') }} then 2
            else 1
        end                                                             as role_rank,
        {{ strip_parenthetical_gloss('concept') }}                      as concept_deglossed
    from concepts_raw
    where nullif(trim(concept), '') is not null

),

concepts as (

    select
        mention_id,
        concept_class,
        role_rank,
        -- the name as the post's enrichment wrote it, gloss removed: what the
        -- canonicaliser reads (folding throws away the accents it needs)
        case when nullif(concept_deglossed, '') is not null
             then concept_deglossed else concept end                   as concept_text,
        -- fold Vietnamese diacritic/case/spacing variants to one key so the same
        -- thing (bánh khọt / banh khot) ranks once, not several times
        {{ fold_concept(
            "case when nullif(concept_deglossed, '') is not null then concept_deglossed else concept end"
        ) }}                                                            as concept_norm
    from concepts_degloss

),

-- generic-commodity stoplist, folded with the SAME macro the concepts are folded
-- with (one folding implementation, both sides). Folded once here rather than in
-- the join predicate so neither engine evaluates a regex per probe row.
generic_terms as (

    select
        {{ fold_concept('term') }}                                      as term_norm,
        applies_to
    from {{ ref('seed_social_generic_terms') }}
    where coalesce(is_active, true)

),

-- Anti-join UPSTREAM of ranking, not a filter on the finished board. Three
-- reasons, the first fatal: (1) row_number() counts every row in its ordering, so
-- removing rows afterwards leaves GAPS in the surviving ranks — the exact thing
-- assert_social_concept_trends_rank_is_dense forbids; (2) mention_share's
-- denominator must exclude generic terms too, or every real item's share is
-- diluted by a constant flood of salt/water/oil; (3) the shared-post divisor must
-- not be inflated by them — a post naming 3 real ingredients plus salt, water and
-- oil should divide by 3, not 6. The cost is that suppressed terms are invisible
-- here; dq_social_generic_term_hits counts them separately so the stoplist stays
-- auditable.
concepts_kept as (

    select c.*
    from concepts as c
    left join generic_terms as g
        on g.term_norm = c.concept_norm
       and (g.applies_to = 'all' or g.applies_to = c.concept_class)
    where g.term_norm is null

)

select
    mention_id,
    concept_class,
    concept_norm,
    concept_text,
    role_rank
from concepts_kept
