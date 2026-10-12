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
--
-- WHAT OUR OWN CUSTOMERS TYPED (2026-10). `web_search`, `pda_ipad_search`, `ust_accounts`
-- and `searched_as` are a SECOND, INDEPENDENT demand signal sitting beside the social one.
-- Social is reach — what the public internet is talking about, almost none of it from
-- anyone who buys from us. These are intent: every one is an account we invoice, typing
-- what it wants into our own search box.
--
--   ust_accounts    HOW MANY OF OUR ACCOUNTS searched for it that week. RANK ON THIS.
--   web_search      searches typed on the website
--   pda_ipad_search searches typed on a handheld or tablet (PDA, Vegas, CatalogFS/FC).
--                   DEVICE, not audience — reps and customers both show up here.
--   searched_as     the spelling the most accounts used. What customers call it.
--
-- Searches and accounts disagree violently and the wrong one flatters: a product can show
-- 56 searches from 20 accounts, while one person re-ordering off a sheet is 260 searches
-- from one. Breadth of accounts is the demand number; search volume says how hard somebody
-- looked, never how many people wanted it.
--
-- A BLANK IS NOT A ZERO. Blank means the search log does not cover that week at all
-- (it starts well after the oldest board weeks); 0 means the log covers it and nobody
-- searched. The two are not the same statement and the query keeps them apart.
--
-- `ust_accounts` 0 BESIDE A NON-ZERO SEARCH COUNT IS REAL, NOT A BUG. 11.8% of searches
-- (13,614 of 114,901) carry no customer_key at all, so they are counted as searches but
-- belong to nobody we can name. It happens on 317 product-weeks. The bulk is reps
-- searching before they have picked a customer — PDA 8,613 and CatalogFS 2,897 — plus
-- 2,050 anonymous searches on the website. Read that row as "somebody looked, we cannot
-- say which account", NOT as "no demand". It is also why ust_accounts is a floor on
-- every row, never an exact headcount.
--
-- DO NOT SUM THESE DOWN THE PAGE. They are attributed to the PRODUCT, and the board can
-- carry one product under two names (an English and a Thai spelling, before concept
-- grouping merges them) — both rows then show the same numbers. That is one population
-- shown twice, not two.

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

),

-- ── what our own customers typed. See the header ──────────────────────────
--
-- The board stores a canonicalised name ('mama instant noodles') and customers type
-- 'mama', so search text cannot be joined onto the board directly — doing that matches
-- about 2 rows in 20 and produces a column of zeros that reads as "nobody searched"
-- rather than "wrong key". Both sides therefore resolve to the same product key through
-- int_social_concept_canon, which exists for exactly this.
--
-- The canon map is keyed on (concept_class, concept_norm), so BOTH of those are joined.
-- Matching on concept_norm alone silently doubles every row for the 2,122 names that sit
-- on the dish and item boards at once.
board_product as (

    select concept_class, concept_norm, product_key
    from ust_databricks.ust_intermediate.int_social_concept_canon

),

-- already rolled up to one row per (product, week), with accounts counted once over the
-- whole product. Deliberately NOT the term-grain model: summing a distinct account count
-- across the spellings of one product counts an account once per spelling it tried, which
-- overstates 271 of 8,735 product-weeks.
search as (

    select product_key, week_start, web_searches, app_searches, ust_accounts, top_search_term
    from ust_databricks.ust_intermediate.int_search_product_weekly

),

-- FALLBACK for board concepts the canon map has never seen — 55 of them, 125 of 836
-- board rows. Those get no product key, so the join above can never reach them no
-- matter how hard customers searched, and the column would read 0 for a reason that
-- has nothing to do with demand.
--
-- It costs real signal. Week-aligned against the current 13-week board, a direct name
-- match recovers 14 rows across three concepts, the best of them well worth having:
--
--     Thai Coffee (Oliang)  2026-08-31   17 mentions   10 accounts   (read as 0)
--     Ice Cream             2026-08-10   29 mentions    2 accounts   (read as 0)
--
-- A row showing 17 mentions AND 10 of our own accounts searching is the strongest
-- corroboration this board can produce, and it was landing as a zero.
--
-- This reads the TERM grain, which is safe here precisely because it is one term —
-- the distinct-account count is taken over that single term and nothing is summed, so
-- the overcount that forced the product-grain model cannot occur. It fires ONLY where
-- the canon map has no row at all, so it can never disagree with the bridge or
-- double-count against it.
search_by_name as (

    select search_term, week_start, web_searches, app_searches, ust_accounts
    from ust_databricks.ust_intermediate.int_search_terms_weekly

),

-- which weeks the search log actually covers, so an uncovered week reads blank rather
-- than 0. The board reaches further back than the event log does, and a 0 there would
-- say "nobody searched" about a week we simply cannot see.
search_coverage as (

    select min(week_start) as first_week, max(week_start) as last_week
    from ust_databricks.ust_intermediate.int_search_product_weekly

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

    -- ── and what OUR customers typed that week. See the header ───────────
    -- Blank = the search log does not cover this week. 0 = it does, and nobody
    -- searched. ust_accounts is the demand number; the two search counts say how
    -- hard people looked, not how many wanted it.
    case when b.week_start between sc.first_week and sc.last_week
         then coalesce(s.ust_accounts, sbn.ust_accounts, 0) end   as ust_accounts,
    case when b.week_start between sc.first_week and sc.last_week
         then coalesce(s.web_searches, sbn.web_searches, 0) end   as web_search,
    case when b.week_start between sc.first_week and sc.last_week
         then coalesce(s.app_searches, sbn.app_searches, 0) end   as pda_ipad_search,
    -- the spelling the most accounts used — what customers call this thing, which
    -- is often not what the board calls it. On a fallback row there is only the one
    -- spelling, which is the board's own name.
    coalesce(s.top_search_term, sbn.search_term)             as searched_as,

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
-- both sides resolve to a product key before meeting; see the board_product comment
left join board_product as bp
       on bp.concept_class = b.concept_class
      and bp.concept_norm  = b.concept_norm
left join search as s
       on s.product_key   = bp.product_key
      and s.week_start    = b.week_start
-- only where the canon map knows nothing at all; see search_by_name
left join search_by_name as sbn
       on bp.product_key is null
      and sbn.search_term = b.concept_norm
      and sbn.week_start  = b.week_start
cross join search_coverage as sc
-- MOSTLY one row per product: int_social_concept_canon merges spellings upstream and
-- does it well (28 names fold into 'rice paper', including banh trang, Thai, German and
-- French). But it only merges names it HAS — 55 board concepts, 125 of 836 rows, have no
-- canon row at all, and those cannot be merged with anything. 'Rice Paper' and 'Rice
-- Paper (bánh tráng)' sit on the board as two rows for that reason, not because grouping
-- failed. So this is not de-duplicated, and a duplicate pair is possible.
order by b.week_start desc,
         case when b.concept_class = 'item' then 0 else 1 end,
         b.board_rank
