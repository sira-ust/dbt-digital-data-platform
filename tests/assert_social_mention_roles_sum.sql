-- assert_social_mention_roles_sum
--
-- Every mention of a concept has exactly one role: the post is ABOUT the concept
-- (subject), it merely NAMED it (ingredient), or it has not been re-labelled at
-- enrichment prompt v4 yet (unlabelled). So the three counts must add up to
-- mention_count, on every row, always.
--
-- This is the guard on the one thing that would make the split lie. The roles come
-- from concept_roles, which aggregates role_rank to the (week, class, concept,
-- mention) grain with max(); mention_count is a plain count over
-- concept_mentions_shared. Those are two paths over the same rows, joined. If that
-- join ever fanned out — two spellings of one concept folding to the same key while
-- carrying different roles is the realistic way — the parts would exceed the whole
-- and a reader would see "20 mentions, 14 subject, 12 ingredient" with nothing else
-- in the model objecting.
--
-- Asserted on the intermediate model, not the mart, so it fails at the source of the
-- arithmetic rather than one join downstream.
--
-- Fails (returns a row) for any concept-week whose roles do not account for exactly
-- its mentions. Severity: error.

select
    week_start,
    concept_class,
    concept_norm,
    mention_count,
    subject_mentions,
    ingredient_mentions,
    unlabelled_mentions,
    subject_mentions + ingredient_mentions + unlabelled_mentions        as role_total
from {{ ref('int_social_concept_trends') }}
where subject_mentions + ingredient_mentions + unlabelled_mentions != mention_count
