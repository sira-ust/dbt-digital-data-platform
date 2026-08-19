-- This week's trending board, with movement — the report to hand a person.
--
-- Frame of reference is the LATEST COMPLETE WEEK in the mart. (Every week in the mart
-- is complete: a calendar week still in progress isn't ranked until it finishes, so
-- max(week_start) never needs qualifying.) Both boards come back, items first, since
-- those are the rows that map to inventory.
--
-- Variations:
--   one board only         -> and b.concept_class = 'item'
--   only things that moved -> and (b.rank_change <> 0 or p.last_week_rank is null)
--   a specific week        -> replace the `latest` CTE with a literal date
--
-- Read `mentions` before believing `movement`: the item board runs on small numbers,
-- so "up 40" on 3 mentions is noise, not a trend. Movement is meaningful once a
-- concept is in double digits.
--
-- An analysis, not a model: dbt compiles it, never builds it. `dbt compile
-- --select social_trending_this_week` writes the runnable SQL to target/compiled/.

with latest as (

    select max(week_start) as wk from {{ ref('mart_social_trending_items') }}

),

-- last week's rank for the same concepts, so the report can say "was 9, now 3".
-- A self-join, not a stored prev_rank column: the mart holds every week, so the
-- comparison is always derivable and never has to be maintained.
prev_week as (

    select m.concept_class, m.concept_norm, m.trend_rank as last_week_rank
    from {{ ref('mart_social_trending_items') }} as m
    cross join latest as l
    where m.week_start = cast({{ dbt.dateadd('day', -7, 'l.wk') }} as date)

),

-- weeks running on the board — separates a one-week spike from something sustained
staying_power as (

    select concept_class, concept_norm, count(*) as weeks_on_board
    from {{ ref('mart_social_trending_items') }}
    where is_top_n
    group by 1, 2

)

select
    b.year_week                                             as week,
    b.concept_class                                         as board,
    b.trend_rank                                            as rank,
    p.last_week_rank                                        as last_week,
    case
        when p.last_week_rank is null then 'NEW'
        when b.rank_change > 0        then concat('up ',   cast(b.rank_change as {{ dbt.type_string() }}))
        when b.rank_change < 0        then concat('down ', cast(abs(b.rank_change) as {{ dbt.type_string() }}))
        when b.rank_change = 0        then 'same'
        -- on the board last week but unranked: one account was driving it
        else 'n/a'
    end                                                     as movement,
    b.concept_label                                         as trending,
    b.mention_count                                         as mentions,
    round(b.mention_share * 100, 1)                         as share_pct,
    case when b.is_rising then 'yes' else 'no' end           as gaining_share,
    s.weeks_on_board,

    -- do we sell it, and what to do about it
    b.result_type,
    b.matched_item_name                                     as our_product,
    b.current_in_stock                                       as in_stock,
    concat_ws(', ', b.recommended_items)                    as suggested_items,
    b.action_signal,
    -- array indexing differs: Databricks is 0-based, DuckDB 1-based
    b.source_links[{{ 0 if target.type == 'databricks' else 1 }}] as example_post

from {{ ref('mart_social_trending_items') }} as b
cross join latest as l
left join prev_week as p
       on p.concept_class = b.concept_class
      and p.concept_norm  = b.concept_norm
left join staying_power as s
       on s.concept_class = b.concept_class
      and s.concept_norm  = b.concept_norm
where b.week_start = l.wk
  and b.is_top_n
  -- one row per real thing: an alias is the same product under a second spelling,
  -- already harmonised onto the same answer, so it would just repeat a row
  and not b.is_alias
order by case when b.concept_class = 'item' then 0 else 1 end,
         b.trend_rank
