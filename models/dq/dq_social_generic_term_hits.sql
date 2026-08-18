{{ config(tags=['social']) }}
-- What the generic-commodity stoplist suppressed, per week — the audit trail for
-- seed_social_generic_terms.
--
-- int_social_concept_trends anti-joins the stoplist BEFORE ranking (it has to:
-- filtering a finished board leaves gaps in the ranks, and the suppressed rows
-- would otherwise dilute the mention_share denominator and inflate the shared-post
-- divisor). The cost of filtering upstream is that suppressed terms are invisible
-- in the trends table, so a stoplist that is quietly eating a real signal — "pork"
-- is a commodity, but if a specific pork product goes viral it lands in the same
-- token — leaves no trace. This model is that trace.
--
-- Grain: one row per (posted_week, concept_class, term_norm) that actually matched
-- something. Read it when the item board looks thin, and when adding terms: a term
-- with a large, RISING hit count is the one to double-check, and a term with zero
-- hits ever is either misspelled relative to what the enrichment extracts (the
-- usual cause for Thai, which fold_concept leaves byte-for-byte) or no longer
-- needed. Since the item class moved to mentioned_products (a product-level
-- extraction) the stoplist is a BACKSTOP rather than the main filter, so falling hit
-- counts here are the expected, healthy direction.
--
-- Deliberately NOT scoped to social_trend_history_weeks: this is a data-quality
-- view over everything collected, and the weeks are already separate rows for the
-- reader to filter. posted_week here is the same Monday-anchored calendar week the
-- trends model ranks on, so hits line up with a board week directly.
--
-- Materialized as a view (dq layer default).

with mentions as (

    select
        mention_id,
        cast(posted_week as date)                                       as posted_week,
        mentioned_dishes,
        mentioned_products
    from {{ ref('fct_social_mentions') }}

),

-- one unnest per select (macros/unnest.sql), same two-stream shape as the trends model
dish_concepts as (

    select
        mention_id, posted_week,
        'dish'                                                          as concept_class,
        {{ unnest('mentioned_dishes') }}                                as concept
    from mentions

),

item_concepts as (

    select
        mention_id, posted_week,
        'item'                                                          as concept_class,
        {{ unnest('mentioned_products') }}                              as concept
    from mentions

),

concepts_raw as (

    select * from dish_concepts
    union all
    select * from item_concepts

),

-- identical normalisation to int_social_concept_trends — degloss, THEN fold, with
-- the same empty-string fallback — kept as two steps for exactly the same reason
-- and in the same order. If these ever diverge this model reports hits the trends
-- model doesn't actually have.
concepts_degloss as (

    select
        mention_id,
        posted_week,
        concept_class,
        concept,
        {{ strip_parenthetical_gloss('concept') }}                      as concept_deglossed
    from concepts_raw
    where nullif(trim(concept), '') is not null

),

concepts as (

    select
        mention_id,
        posted_week,
        concept_class,
        {{ fold_concept(
            "case when nullif(concept_deglossed, '') is not null then concept_deglossed else concept end"
        ) }}                                                            as concept_norm
    from concepts_degloss

),

generic_terms as (

    select
        {{ fold_concept('term') }}                                      as term_norm,
        applies_to,
        reason,
        coalesce(is_active, true)                                       as is_active
    from {{ ref('seed_social_generic_terms') }}

)

select
    c.posted_week,
    c.concept_class,
    g.term_norm,
    g.reason,
    g.is_active,
    -- what the anti-join actually removed (is_active = false rows are reported too,
    -- so you can see what a term WOULD suppress before switching it on)
    g.is_active                                                        as is_suppressed,
    count(*)                                                           as concept_mention_hits,
    count(distinct c.mention_id)                                       as distinct_mentions
from concepts as c
inner join generic_terms as g
    on g.term_norm = c.concept_norm
   and (g.applies_to = 'all' or g.applies_to = c.concept_class)
group by 1, 2, 3, 4, 5, 6
