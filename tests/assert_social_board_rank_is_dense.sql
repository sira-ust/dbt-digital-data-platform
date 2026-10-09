-- assert_social_board_rank_is_dense
--
-- board_rank runs 1..N with no gaps or repeats, per (week, class), over exactly the
-- products on the board. Same guarantee the weekly trend_rank has
-- (assert_social_concept_trends_rank_is_dense): "#5" must mean four products are
-- ahead of it, never three because a filter removed one after ranking.
--
-- Fails (returns a row) per (week, class) whose ranks are not exactly 1..count.
-- Severity: error.

select
    week_start,
    concept_class,
    count(*)                    as on_board,
    min(board_rank)             as min_rank,
    max(board_rank)             as max_rank,
    count(distinct board_rank)  as distinct_ranks
from {{ ref('int_social_trend_board') }}
where is_on_board
group by week_start, concept_class
having min(board_rank) <> 1
    or max(board_rank) <> count(*)
    or count(distinct board_rank) <> count(*)
