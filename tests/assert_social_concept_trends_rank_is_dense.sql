-- assert_social_concept_trends_rank_is_dense
--
-- trend_rank in int_social_concept_trends should be dense (1..N, no gaps)
-- among ranked concepts (author_quality != 'repeat_poster'; excluded concepts
-- get NULL, not a gap). row_number() over a window still counts every row in
-- its ordering even when the result is nulled out afterward for some of them —
-- ranking has to run over the already-filtered subset, then join the rank
-- back, or gaps appear exactly where excluded concepts used to sit.
--
-- Fails (returns a row) if the count of distinct non-null ranks doesn't equal
-- the max rank — the only way that can happen is a gap.
-- Severity: error — a gap means the ranking query itself regressed, not a
-- data-quality issue to merely flag.

select
    count(distinct trend_rank) as distinct_ranks,
    max(trend_rank)            as max_rank
from {{ ref('int_social_concept_trends') }}
where trend_rank is not null
having count(distinct trend_rank) != max(trend_rank)
