-- assert_social_board_shelf_before_generic
--
-- The board's order, on every week's board (int_social_trend_board, ORDER):
--   1. every product posted about this week (board_section 'posted') ranks above every
--      product with no posts this week that is still fading off ('quiet'), on both
--      boards: the fade keeps a product ON the board, it must not hold it at the top;
--   2. within each section of the ITEM board, every shelf product (branded or shelf:
--      something a store can stock) ranks above every generic category. The two scopes
--      are ranked separately precisely so that a broad staple — "fish sauce", "ice cream"
--      — can sit on the board without ever pushing a stockable product down it. The dish
--      board ranks on buzz alone, so it is not checked for this.
--
-- Fails (returns a row) per (week, class[, section]) where the order breaks. Severity: error.

select
    week_start,
    concept_class,
    'quiet above posted'                                        as problem
from {{ ref('int_social_trend_board') }}
where is_on_board
group by week_start, concept_class
having max(case when board_section = 'posted' then board_rank end)
     > min(case when board_section = 'quiet' then board_rank end)

union all

select
    week_start,
    concept_class,
    'generic above shelf in ' || board_section                  as problem
from {{ ref('int_social_trend_board') }}
where is_on_board
  and concept_class = 'item'
group by week_start, concept_class, board_section
having max(case when is_shelf_product then board_rank end)
     > min(case when not is_shelf_product then board_rank end)
