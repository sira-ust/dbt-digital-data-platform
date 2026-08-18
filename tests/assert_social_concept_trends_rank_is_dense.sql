-- assert_social_concept_trends_rank_is_dense
--
-- trend_rank is a rank space PER (week_start, concept_class): dishes and items are
-- ranked separately so dishes can't crowd items off the board, and every observed
-- as-of week gets its own board. Within each of those spaces the rank must be
-- dense — 1..N, no gaps, no duplicates.
--
-- Excluded concepts (author_quality = 'repeat_poster') get NULL, not a gap.
-- row_number() over a window still counts every row in its ordering even when the
-- result is nulled out afterward for some of them, so ranking has to run over the
-- already-filtered subset PER PARTITION and then be joined back, or gaps appear
-- exactly where excluded concepts used to sit. Same reason the stoplist anti-join
-- happens upstream of ranking rather than as a filter on the finished board.
--
-- Three ways a partition can be wrong, all caught here:
--   gap        max_rank  > n_ranked         — something consumed a rank number
--   duplicate  n_ranked  > n_distinct_ranks — the partition-by list lost week_start
--              or concept_class, so two boards' ranks landed in one space. This is
--              the likeliest regression in the weekly/two-class structure, and the
--              previous table-wide scalar version of this test could not see it.
--   wrong base min_rank != 1                — the space doesn't start at 1
--
-- Returns one row per offending (week_start, concept_class); store_failures is on
-- globally, so the failing weeks/classes are inspectable in test_failures.
-- Severity: error — this is the ranking query regressing, not a data-quality issue
-- to merely flag.

select
    week_start,
    concept_class,
    count(*)                   as n_ranked,
    count(distinct trend_rank) as n_distinct_ranks,
    min(trend_rank)            as min_rank,
    max(trend_rank)            as max_rank
from {{ ref('int_social_concept_trends') }}
where trend_rank is not null
group by 1, 2
having count(distinct trend_rank) != count(*)
    or max(trend_rank) != count(*)
    or min(trend_rank) != 1
