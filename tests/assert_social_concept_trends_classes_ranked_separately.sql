-- assert_social_concept_trends_classes_ranked_separately
--
-- The whole point of concept_class is that dishes and items are ranked in SEPARATE
-- spaces, so a flood of viral dishes can't push stockable items off the board. If a
-- class has any ranked row in a week, it must have its own rank 1 that week.
--
-- What this catches that the density test doesn't: a partition-by list of
-- (week_start) alone still produces a dense 1..N per week, and the density test
-- passes — but then one class holds ranks 1..18 and the other 19..20, which is
-- exactly the masking this design exists to remove. Here that shows up as a class
-- with ranked rows and no rank 1.
--
-- Returns one row per offending (week_start, concept_class).
-- Severity: error — the two boards have silently merged back into one.

select
    week_start,
    concept_class,
    count(*)        as n_ranked,
    min(trend_rank) as min_rank
from {{ ref('int_social_concept_trends') }}
where trend_rank is not null
group by 1, 2
having min(trend_rank) != 1
