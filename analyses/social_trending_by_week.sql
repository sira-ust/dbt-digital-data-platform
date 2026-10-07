-- The social trending board for EVERY week — paste into the Databricks SQL editor and
-- run, then use the download button for Excel/CSV.
--
-- Plain SQL with no Jinja, matching every other file in analyses/. dbt never BUILDS an
-- analysis, so ref() and the dbt.* dispatch macros only bought lineage in the docs graph,
-- and they cost the one thing this file is for: being pasted somewhere and run. Tables are
-- named in full and the dialect is Databricks — the mart only holds real data there (local
-- duckdb has almost no enriched mentions), so cross-engine portability was never worth
-- anything here either. One real cost, stated plainly: a schema rename will not follow
-- this file the way it would follow a ref().
--
-- One row per (week, board, rank), newest week first — the current board is the top of
-- the result, no filtering needed. To narrow it:
--   latest week only        -> and b.week_start = (select max(week_start) from ust_databricks.ust_reporting.mart_social_trending_items)
--   a specific week         -> and b.year_week = '2026-W33'
--   one board only          -> and b.concept_class = 'item'
--   things we could stock   -> and b.is_shelf_product
--   only things that moved  -> and (b.board_rank <> p.last_week_rank or p.last_week_rank is null)
--
-- THE BOARD HAS STAYING POWER (2026-10). A product earns its place on a faded score —
-- this week's share of posts plus a fading memory of earlier weeks — so a viral product
-- stays on while it trails off (about 3-4 quiet weeks) instead of vanishing the first
-- quiet week. That is why a row can show 0 mentions: read `status` and `quiet_weeks`
-- beside `mentions`. `low_coverage_week` = yes means the feed delivered far fewer posts
-- than in the previous 4 weeks (quota out, keyword change). Such a week stops the fade
-- clock (`fade_paused` = yes), because silence then says nothing about the product —
-- but for at most 2 weeks in a row: a drop that lasts is the feed's new size, and a
-- product nobody posts about then fades like any other.
--
-- STOCKABLE FIRST, ON THE ITEM BOARD. Branded and shelf products (`type`) rank ahead of
-- generic categories, so `rank` 1-N is the stockable list and the generic rows follow;
-- `stockable_rank` numbers the stockable rows alone. The dish board ranks on buzz alone.
--
-- The two boards are ranked SEPARATELY and both come back, items first: 'item' is things
-- we could stock, 'dish' is what people are eating.
--
-- Every week here is COMPLETE: a calendar week in progress is not ranked until it
-- finishes, so there is no partial week at the leading edge.
--
-- `in_stock`, `our_products` and `action_signal` are always about TODAY, even on an older
-- week's row — they describe what to do now, not what was true then.
--
-- `our_products` lists EVERY SKU we stock the trending item under (our_sku_count says how
-- many), matched brand first and then rotating across the others. It is derived from item
-- NAMES, so it is a floor: a SKU whose name uses different words is left out rather than
-- guessed at. Read a short list as "these are definitely it", not "this is all we have".

with observed_weeks as (

    -- which weeks exist at all. Needed to tell "new to the board" from "there is no
    -- earlier week to compare against" — at the earliest week EVERY row would otherwise
    -- read as NEW, which is a boundary artifact, not a signal.
    select distinct week_start
    from ust_databricks.ust_reporting.mart_social_trending_items

),

board as (

    select *
    from ust_databricks.ust_reporting.mart_social_trending_items
    where is_top_n

),

prev_week as (

    -- last week's board rank for the same product; null when it was not on the board
    select concept_class, concept_norm, week_start, board_rank as last_week_rank
    from ust_databricks.ust_reporting.mart_social_trending_items
    where is_top_n

)

select
    b.year_week                                              as week,
    b.week_start,
    b.concept_class                                          as board,
    b.board_rank                                             as rank,
    case when b.is_shelf_product and b.concept_class = 'item'
         then b.scope_rank end                              as stockable_rank,
    p.last_week_rank                                         as last_week,
    case
        -- no earlier week exists — not the same thing as "new to the board"
        when ow.week_start is null              then 'first week'
        when p.last_week_rank is null           then 'NEW'
        when b.board_rank < p.last_week_rank    then concat('up ',   cast(p.last_week_rank - b.board_rank as string))
        when b.board_rank > p.last_week_rank    then concat('down ', cast(b.board_rank - p.last_week_rank as string))
        else 'same'
    end                                                      as movement,
    b.concept_label                                          as trending,
    b.product_type                                           as type,
    b.brand,
    -- new / rising / steady / cooling: where the product is in its run
    b.board_status                                           as status,
    b.weeks_on_board,
    b.best_board_rank                                        as best_rank,

    -- this week's evidence. 0 mentions on a 'steady' or 'cooling' row is the product
    -- trailing off, not an error; quiet_weeks counts the normal-coverage weeks in a row
    -- without a post (it leaves the board after 4)
    coalesce(b.mention_count, 0)                             as mentions,
    round(b.mention_share * 100, 1)                          as share_pct,
    b.quiet_weeks,
    case when b.is_low_coverage then 'yes' else 'no' end      as low_coverage_week,
    case when b.is_fade_paused  then 'yes' else 'no' end      as fade_paused,
    -- the Rising list: biggest share growth over the last 4 weeks vs the 8 before;
    -- null when the product is not on it
    b.rising_rank,

    -- "which Pepsi? which Magnum?": related products of the same brand (or longer names
    -- containing this one) with their posts over the last 4 weeks
    concat_ws(', ', b.top_variants)                          as variants,

    -- do we sell it, and what to do about it
    b.result_type,
    b.carried_sku_count                                      as our_sku_count,
    concat_ws(', ', b.carried_items)                         as our_products,
    -- in_stock is about ONE part number — the resolver's representative pick, named
    -- here so the number is attributable. It is NOT "can we ship this today": the other
    -- SKUs in our_products have their own stock, so a 'restock' beside a long
    -- our_products list means that particular SKU is out, not the product.
    b.matched_item_name                                      as stock_checked_on,
    b.current_in_stock                                       as in_stock,
    -- what to offer when we do NOT carry the thing itself: substitutes, or the
    -- ingredient basket for a dish
    concat_ws(', ', b.recommended_items)                     as suggested_items,
    -- real SKUs the resolver found but was not confident enough to recommend — shown
    -- only on a 'none' row, and the reason action_signal says review_nearest instead of
    -- source_new. Worth a look before anyone goes sourcing.
    concat_ws(', ', b.nearest_items)                         as nearest_items,
    b.action_signal,

    -- EVERY link, as the array itself (up to 5 posts). A CSV/Excel download serialises
    -- it to ["url", "url", …]; for plain text use concat_ws(', ', b.source_links).
    b.source_links                                           as example_post

from board as b
left join prev_week as p
       on p.concept_class = b.concept_class
      and p.concept_norm  = b.concept_norm
      and p.week_start    = date_add(b.week_start, -7)
left join observed_weeks as ow
       on ow.week_start   = date_add(b.week_start, -7)
-- no de-duplication needed: every spelling of a product is merged upstream
-- (int_social_concept_canon), so the board carries one row per real product
order by b.week_start desc,
         case when b.concept_class = 'item' then 0 else 1 end,
         b.board_rank
