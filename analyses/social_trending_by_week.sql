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
--   only things that moved  -> and (b.rank_change <> 0 or p.last_week_rank is null)
--
-- The two boards are ranked SEPARATELY and both come back, items first: 'item' is things
-- we could stock, 'dish' is what people are eating. Ranking them together let a viral
-- dish bury every stockable signal, which is the whole reason for the split.
--
-- Every week here is COMPLETE: a calendar week in progress is not ranked until it
-- finishes, so there is no partial week at the leading edge.
--
-- Read `mentions` before believing `movement`: the item board runs on small numbers, so
-- "up 40" on 3 mentions is noise. Movement is meaningful in double digits.
--
-- `in_stock`, `our_product` and `action_signal` are always about TODAY, even on an older
-- week's row — they describe what to do now, not what was true then.

with observed_weeks as (

    -- which weeks exist at all. Needed to tell "new to the board" from "there is no
    -- earlier week to compare against" — at the earliest week EVERY row would otherwise
    -- read as NEW, which is a boundary artifact, not a signal.
    select distinct week_start
    from ust_databricks.ust_reporting.mart_social_trending_items

),

board as (

    -- weeks on the board, counted AS OF each week rather than over all time. A running
    -- count is the only honest version in a multi-week report: a total would put "4 weeks
    -- on board" on a row from week 1, counting weeks that had not happened yet.
    select *,
        count(*) over (
            partition by concept_class, concept_norm
            order by week_start
            rows between unbounded preceding and current row
        ) as weeks_on_board
    from ust_databricks.ust_reporting.mart_social_trending_items
    where is_top_n

),

prev_week as (

    -- last week's rank for the same concept. Reads the FULL mart, not `board`, so a
    -- concept that slipped off the top-N still reports the rank it actually held.
    -- A self-join, not a stored prev_rank column: the mart holds every week, so the
    -- comparison is always derivable and never has to be maintained.
    select concept_class, concept_norm, week_start, trend_rank as last_week_rank
    from ust_databricks.ust_reporting.mart_social_trending_items

)

select
    b.year_week                                              as week,
    b.week_start,
    b.concept_class                                          as board,
    b.trend_rank                                             as rank,
    p.last_week_rank                                         as last_week,
    case
        -- no earlier week exists — not the same thing as "new to the board"
        when ow.week_start is null    then 'first week'
        when p.last_week_rank is null then 'NEW'
        when b.rank_change  >  0      then concat('up ',   cast(b.rank_change as string))
        when b.rank_change  <  0      then concat('down ', cast(abs(b.rank_change) as string))
        when b.rank_change  =  0      then 'same'
        else 'n/a'   -- on the board last week but unranked (one account was driving it)
    end                                                      as movement,
    b.concept_label                                          as trending,
    b.mention_count                                          as mentions,
    round(b.mention_share * 100, 1)                          as share_pct,
    case when b.is_rising then 'yes' else 'no' end            as gaining_share,
    b.weeks_on_board,

    -- do we sell it, and what to do about it
    b.result_type,
    b.matched_item_name                                      as our_product,
    b.current_in_stock                                       as in_stock,
    concat_ws(', ', b.recommended_items)                     as suggested_items,
    b.action_signal,

    -- EVERY link, as the array itself. The mart holds up to 5 posts per concept and one
    -- is not enough to judge a trend by. A CSV/Excel download serialises it to
    -- ["url", "url", …]; if you need plain text in the cell, use
    -- concat_ws(', ', b.source_links) instead.
    b.source_links                                           as example_post

from board as b
left join prev_week as p
       on p.concept_class = b.concept_class
      and p.concept_norm  = b.concept_norm
      and p.week_start    = date_add(b.week_start, -7)
left join observed_weeks as ow
       on ow.week_start   = date_add(b.week_start, -7)
-- no de-duplication needed here: concepts the resolver judged to be one thing are
-- merged upstream in int_social_concept_trends, BEFORE aggregation, so the board
-- already carries one row per real thing with the mentions combined
order by b.week_start desc,
         case when b.concept_class = 'item' then 0 else 1 end,
         b.trend_rank
