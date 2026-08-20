-- The trending board for EVERY week in the mart — filter to the week you want.
--
-- One row per (week, board, rank). Both boards come back, items first within a week,
-- since those are the rows that map to inventory. Newest week first, so the top of the
-- result is the current board without any filtering.
--
-- Variations:
--   latest week only       -> and b.week_start = (select max(week_start) from …)
--   one board only         -> and b.concept_class = 'item'
--   only things that moved -> and (b.rank_change <> 0 or p.last_week_rank is null)
--   a specific week        -> and b.year_week = '2026-W32'
--
-- Every week here is COMPLETE: a calendar week still in progress is not ranked until it
-- finishes, so there is no partial week at the leading edge to explain away.
--
-- Read `mentions` before believing `movement`: the item board runs on small numbers, so
-- "up 40" on 3 mentions is noise, not a trend. Movement is meaningful in double digits.
--
-- An analysis, not a model: dbt compiles it, never builds it. `dbt compile --select
-- social_trending_by_week` writes the runnable SQL to target/compiled/.

with observed_weeks as (

    -- which weeks exist at all. Needed to tell "this concept is new to the board" from
    -- "there is no earlier week to compare against" — at the earliest week in the mart
    -- EVERY row would otherwise read as NEW, which is a boundary artifact, not a signal.
    select distinct week_start from {{ ref('mart_social_trending_items') }}

),

board as (

    -- weeks on the board, counted AS OF each week rather than over all time. A running
    -- count is the only honest version in a multi-week report: a total would put "4
    -- weeks on board" on a row from week 1, counting weeks that had not happened yet.
    select *,
        count(*) over (
            partition by concept_class, concept_norm
            order by week_start
            rows between unbounded preceding and current row
        ) as weeks_on_board
    from {{ ref('mart_social_trending_items') }}
    where is_top_n

),

prev_week as (

    -- last week's rank for the same concept. Reads the FULL mart, not `board`, so a
    -- concept that slipped off the top-N still reports the rank it actually held.
    -- A self-join, not a stored prev_rank column: the mart holds every week, so the
    -- comparison is always derivable and never has to be maintained.
    select concept_class, concept_norm, week_start, trend_rank as last_week_rank
    from {{ ref('mart_social_trending_items') }}

)

select
    b.year_week                                             as week,
    b.week_start,
    b.concept_class                                         as board,
    b.trend_rank                                            as rank,
    p.last_week_rank                                        as last_week,
    case
        -- no earlier week exists in the mart — not the same thing as "new to the board"
        when ow.week_start is null     then 'first week'
        when p.last_week_rank is null  then 'NEW'
        when b.rank_change > 0         then concat('up ',   cast(b.rank_change as {{ dbt.type_string() }}))
        when b.rank_change < 0         then concat('down ', cast(abs(b.rank_change) as {{ dbt.type_string() }}))
        when b.rank_change = 0         then 'same'
        -- on the board last week but unranked: one account was driving it
        else 'n/a'
    end                                                     as movement,
    b.concept_label                                         as trending,
    b.mention_count                                         as mentions,
    round(b.mention_share * 100, 1)                         as share_pct,
    case when b.is_rising then 'yes' else 'no' end           as gaining_share,
    b.weeks_on_board,

    -- do we sell it, and what to do about it
    b.result_type,
    b.matched_item_name                                     as our_product,
    -- CURRENT stock and the action that follows from it: both are about TODAY, so on an
    -- older week's row they describe now, not then. See the mart's stock CTE.
    b.current_in_stock                                      as in_stock,
    concat_ws(', ', b.recommended_items)                    as suggested_items,
    b.action_signal,
    -- array indexing differs: Databricks is 0-based, DuckDB 1-based
    b.source_links[{{ 0 if target.type == 'databricks' else 1 }}] as example_post

from board as b
left join prev_week as p
       on p.concept_class = b.concept_class
      and p.concept_norm  = b.concept_norm
      and p.week_start     = cast({{ dbt.dateadd('day', -7, 'b.week_start') }} as date)
left join observed_weeks as ow
       on ow.week_start    = cast({{ dbt.dateadd('day', -7, 'b.week_start') }} as date)
-- no de-duplication needed here: concepts the resolver judged to be one thing are
-- merged upstream in int_social_concept_trends, before aggregation, so the board
-- already carries one row per real thing with the mentions combined
order by b.week_start desc,
         case when b.concept_class = 'item' then 0 else 1 end,
         b.trend_rank
