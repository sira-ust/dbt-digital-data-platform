{{ config(tags=['social']) }}
-- mart_social_trending_items — the marketing-facing weekly trending board. One row
-- per (CALENDAR WEEK, concept_class, concept_norm); recomputed and REPLACED each run.
--
-- Time windows (ranking, comparison, retention) are defined once in
-- models/docs/_social_windows.md. Two consequences to know here: every week on this
-- board is a COMPLETE week — the in-progress one isn't computed until it finishes, so
-- max(week_start) is never half-counted — and the movement columns are STRICT, filled
-- in only when the previous row is exactly last week (null = no comparison, not flat).
--
-- READING IT — two questions, one table:
--   what's trending THIS WEEK -> where is_top_n and week_start = (select max(week_start) ...)
--                                ~social_trend_top_n rows per class
--   what's RISING             -> a concept's rows across week_start, via rank_change /
--                                mention_share_change / is_rising
--
-- TWO CLASSES, ranked separately (concept_class), each with its own 1..N per week so
-- viral dishes cannot mask the inventory-facing signal. Show both:
--   'dish' — Som Tam, Pho, banh khot: what people talk about
--   'item' — Tiparos fish sauce, canned coconut milk: goods a grocery or restaurant
--            could order. Raw commodities (durian, pork) are deliberately not here.
-- The item board is much thinner by nature — people post about dishes, not SKUs.
--
-- Per trending thing it answers:
--   1. what's trending, how hard, is it moving  (rank, mentions, score, mention_share, rank_change)
--   2. where to see it                          (source_links)
--   3. do we carry it                           (result_type + matched item + current stock)
--   4. if not, what similar to offer            (recommended_items)
--   5. what to DO                               (action_signal)
--
-- TRAJECTORIES ARE COMPLETE, NOT TOP-N-FILTERED: rows are kept for every week of any
-- concept that reached the top N in ANY week, and is_top_n flags the weeks it was
-- actually on the board — a chart filtered to top-N alone would have holes wherever a
-- concept dipped out. One honest gap: a week below social_trend_min_mentions has no
-- upstream row at all, so it is missing rather than zero.
--
-- Lineage: int_social_concept_trends (per-week ranking + source_links) LEFT JOIN
-- stg_mentionlytics__concept_resolution (offline LLM concept->SKU) LEFT JOIN
-- int_jdawms_items_active (authoritative name) LEFT JOIN int_jdawms_stock_weekly
-- (CURRENT stock, latest snapshot week). dbt never calls the LLM.
--
-- CONFIDENCE FLOOR (social_resolve_min_confidence) applies to ANY match — carried,
-- substitute or basket. An inventory match wins, but only when it is actually
-- confident: a 0.45 carried guess (sushi -> corn oil) is a bad guess, not a hit, and
-- is suppressed like a shaky basket (shown as 'none' / source_new). Since the
-- resolver's v5 two-pass design the floor gates a VERIFIED confidence — a second,
-- independent model's calibrated certainty in the items that survived its review —
-- not the proposer's self-rating, which clustered just above the floor and made it
-- inert.

with trends as (

    select * from {{ ref('int_social_concept_trends') }}

),

-- concepts that reached the board in ANY week, per class. `select distinct` is
-- mandatory: without it the join below fans out by the number of weeks the concept
-- was top-N. The class must be part of the key too, or a string that is a top-N
-- dish and a long-tail item would drag the item's trajectory in on the dish's ticket.
qualifying as (

    select distinct concept_class, concept_norm
    from trends
    where trend_rank <= {{ var('social_trend_top_n') }}

),

board as (

    select
        t.*,
        -- `trend_rank is not null and ...`, not a bare comparison: a concept excluded
        -- that week as a repeat_poster has NO rank, and `NULL <= 20` is NULL, not
        -- false — which left is_top_n null on a trajectory row and failed its not_null
        -- test on real data (2026-08-19). No rank means not on the board, which is
        -- false, not unknown.
        t.trend_rank is not null
            and t.trend_rank <= {{ var('social_trend_top_n') }}          as is_top_n
    from trends as t
    inner join qualifying as q
        on q.concept_class = t.concept_class
       and q.concept_norm  = t.concept_norm

),

resolution as (

    select * from {{ ref('stg_mentionlytics__concept_resolution') }}

),

-- ACTIVE items only — a discontinued item is a bad "we carry this" or
-- "here's a substitute" answer, even if it's still in the item master. The
-- resolver already filtered to this same model, but it runs BEFORE the build:
-- re-checking here drops anything deactivated in between.
items as (

    select prtnum, item_name, item_family
    from {{ ref('int_jdawms_items_active') }}

),

-- CURRENT stock: the latest snapshot week per item (roll wh/client up first).
-- Deliberately NOT as-of the trend week — hence the current_* naming below. A
-- week-10 row carrying week-10 stock would make action_signal a decision about
-- the past, and "promote_now" is a decision about today.
stock_weekly as (

    select
        prtnum,
        week_start,
        max(in_stock)                                                   as in_stock,
        sum(shippable_qty)                                              as shippable_qty
    from {{ ref('int_jdawms_stock_weekly') }}
    group by 1, 2

),

stock as (

    select prtnum, in_stock, shippable_qty
    from (
        select
            prtnum, in_stock, shippable_qty,
            row_number() over (partition by prtnum order by week_start desc) as _rn
        from stock_weekly
    )
    where _rn = 1

),

-- The concept->SKU resolution is applied at CONCEPT grain, before it ever meets
-- the weekly rows. Two reasons: the confidence floor is a property of the
-- resolution (not of a week), and the recommendation arrays must be exploded and
-- re-aggregated exactly once — doing it after the join to the weekly board would
-- aggregate the same array once per week and produce arrays N times too long.
resolution_adj as (

    select
        concept_norm,
        canonical_label,
        alias_of,
        result_type                                                     as raw_result_type,
        matched_prtnum                                                  as raw_matched_prtnum,
        recommended_prtnums,
        match_confidence,
        -- floor applies to ANY match (carried / substitute / basket): inventory
        -- wins, but only when the match is actually confident. A low-confidence
        -- carried match is a bad guess (sushi -> corn oil @0.45), not a real
        -- inventory hit, so it's suppressed just like a shaky basket.
        result_type in ('carried', 'substitute', 'basket')
            and coalesce(match_confidence, 0)
                < {{ var('social_resolve_min_confidence') }}             as _low_conf
    from resolution

),

resolution_final as (

    select
        *,
        case when _low_conf then 'none' else raw_result_type end         as result_type_adj,
        case when _low_conf then null else raw_matched_prtnum end        as matched_prtnum
    from resolution_adj

),

-- VERIFY recommendations against the real item master, then collapse duplicates.
-- The resolution table stores what the LLM returned, so a hallucinated SKU or a
-- name that disagrees with its prtnum can be in there (matched_item_name is
-- already verified via the items join; recommendations were not). Explode, inner
-- join to the ACTIVE items — dropping any prtnum that isn't a real, sellable SKU
-- — and take the AUTHORITATIVE name from the master, never the LLM's claimed name.
rec_exploded as (

    select
        r.concept_norm,
        {{ unnest('r.recommended_prtnums') }}                            as rec_prtnum
    from resolution_final as r
    where not r._low_conf
      and r.recommended_prtnums is not null

),

-- one row per (concept, distinct product). Two collapses, both deliberate:
--   * distinct prtnum — the array can repeat a SKU;
--   * one row per item_name — the master carries several part numbers with the
--     SAME name (21405 and 21406 are both 'DF TOMYUM PASTE'), and listing one
--     product twice reads as a padded basket. Lowest prtnum wins, so the choice
--     is deterministic across runs.
rec_verified as (

    select concept_norm, rec_prtnum, item_name
    from (
        select
            re.concept_norm,
            re.rec_prtnum,
            itm.item_name,
            row_number() over (
                partition by re.concept_norm, itm.item_name
                order by re.rec_prtnum
            )                                                          as _name_rn
        from (select distinct concept_norm, rec_prtnum from rec_exploded) as re
        inner join items as itm
            on itm.prtnum = re.rec_prtnum
    )
    where _name_rn = 1

),

-- Both array_agg()s run over the SAME rows in ONE aggregate, so item name [i] is
-- always the name of prtnum [i] — neither engine specifies ordering BETWEEN two
-- aggregates, but a single aggregate operator fills both buffers row by row in one
-- pass, and both values come from the same row either way. Length equality is
-- asserted by tests/assert_social_recommendations_aligned.sql.
rec_agg as (

    select
        concept_norm,
        array_agg(rec_prtnum)                                          as recommended_prtnums,
        array_agg(item_name)                                           as recommended_items
    from rec_verified
    group by 1

),

joined as (

    select
        b.week_start,
        b.concept_class,
        b.concept_norm,
        b.is_top_n,
        b.week_end,
        b.year_week,

        coalesce(r.canonical_label, b.concept_norm)                     as concept_label,
        -- kept in this CTE, NOT published: is_alias below is the only usable form of
        -- it. Same dish under two concept keys (som tam / ส้มตำ — fold_concept merges
        -- Latin diacritics only, never cross-script) gets harmonised onto the
        -- better-grounded answer by the resolver, and both rows still take a board
        -- slot; a reader only needs to know which one to hide.
        r.alias_of,
        b.trend_rank,
        b.rank_change,
        b.mention_count,
        b.mention_count_wow_pct,
        b.mention_share,
        b.mention_share_change,
        b.total_engagement,
        b.total_views,
        b.is_rising,
        b.source_links,
        -- author-diversity trust signal, surfaced (not just computed internally) —
        -- an 'unverifiable' concept stays on the board rather than being silently
        -- dropped, but marketing should see why it couldn't be confirmed.
        b.distinct_authors_adj,
        b.author_quality,
        b.is_single_channel,
        -- the resolution is keyed on concept_norm ONLY, on purpose: a concept->SKU
        -- mapping is timeless, so the same mapping correctly attaches to every one
        -- of a concept's weekly rows. Do not add a date to this join.
        r.result_type_adj,
        r.matched_prtnum,
        r.match_confidence
    from board as b
    left join resolution_final as r
        on r.concept_norm = b.concept_norm

)

select
    -- grain
    cast(j.week_start as {{ dbt.type_string() }}) || '|' || j.concept_class
        || '|' || j.concept_norm                                        as concept_key,
    j.week_start,
    j.concept_class,
    j.concept_norm,
    j.concept_label,
    j.is_top_n,

    -- the calendar week this row covers. year_week ("2026-W34") is the display label;
    -- week_start is the date to sort and join on; week_end closes the range.
    j.week_end,
    j.year_week,

    -- social trend signal
    j.trend_rank,
    j.mention_count,
    j.mention_share,
    j.total_engagement,
    j.total_views,
    j.source_links,
    j.distinct_authors_adj                                             as distinct_authors,
    j.author_quality,
    j.is_single_channel,

    -- movement. rank_change is POSITIVE when the concept moved UP the board;
    -- mention_share_change is the volume-neutral one (see int_social_concept_trends
    -- on why is_rising alone can't be trusted). Nulls mean "no comparison exists",
    -- not "flat".
    j.rank_change,
    j.mention_count_wow_pct,
    j.mention_share_change,
    j.is_rising,

    -- do we carry it? (unresolved = the gate hasn't scored this concept yet)
    coalesce(j.result_type_adj, 'unresolved')                          as result_type,
    j.matched_prtnum,
    itm.item_name                                                      as matched_item_name,
    -- CURRENT stock, not as-of this row's week — see the stock CTE
    st.in_stock                                                        as current_in_stock,
    st.shippable_qty                                                   as current_shippable_qty,

    -- recommendations: only real SKUs (verified against the item master), shown
    -- with their authoritative names; dropped when the match was low-confidence
    ra.recommended_prtnums,
    ra.recommended_items,
    -- only meaningful when there's an actual match shown; null for none/unresolved
    -- (a confidence score on a "no match" is noise)
    case when j.result_type_adj in ('carried', 'substitute', 'basket')
         then j.match_confidence end                                    as match_confidence,
    j.alias_of is not null                                             as is_alias,

    -- what marketing should do (about TODAY's stock — see the stock CTE)
    case
        when j.result_type_adj = 'carried'    and coalesce(st.in_stock, 0) = 1 then 'promote_now'
        when j.result_type_adj = 'carried'    and coalesce(st.in_stock, 0) = 0 then 'restock'
        when j.result_type_adj = 'substitute'                                  then 'offer_substitute'
        when j.result_type_adj = 'basket'                                      then 'promote_ingredients'
        when j.result_type_adj = 'none'                                        then 'source_new'
        else 'monitor'
    end                                                                as action_signal

from joined as j
left join items as itm
    on itm.prtnum = j.matched_prtnum
left join stock as st
    on st.prtnum = j.matched_prtnum
left join rec_agg as ra
    on ra.concept_norm = j.concept_norm
