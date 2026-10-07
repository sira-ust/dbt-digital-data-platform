-- assert_social_board_shelf_before_generic
--
-- On every week's ITEM board, every shelf product (branded or shelf: something a store can
-- stock) ranks above every generic category. The two scopes are ranked separately
-- precisely so that a broad staple — "fish sauce", "ice cream" — can sit on the board
-- without ever pushing a stockable product like "lay's ice cream" down it; this fails
-- if any generic product's board_rank is better than any shelf product's. The dish
-- board ranks on buzz alone, so it is not checked.
--
-- Fails (returns a row) per (week, class) where the scopes interleave. Severity: error.

select
    week_start,
    concept_class,
    max(case when is_shelf_product then board_rank end)         as worst_shelf_rank,
    min(case when not is_shelf_product then board_rank end)     as best_generic_rank
from {{ ref('int_social_trend_board') }}
where is_on_board
  and concept_class = 'item'
group by week_start, concept_class
having max(case when is_shelf_product then board_rank end)
     > min(case when not is_shelf_product then board_rank end)
