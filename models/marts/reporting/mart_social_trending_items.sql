{{ config(tags=['social']) }}
-- mart_social_trending_items — the marketing-facing weekly trending board. Grain:
-- one row per (CALENDAR WEEK, concept_class, concept_norm). The report runs weekly
-- and each row covers exactly one Monday-anchored week's mentions, ranked against
-- only that week's other concepts, so week-to-week movement is a comparison of
-- equal, non-overlapping periods. Recomputed and REPLACED each run.
--
-- READING IT — two different questions, one table:
--   "what's trending THIS WEEK" -> where is_top_n and week_start = (select max(week_start) ...)
--                                  ~social_trend_top_n rows per class
--   "what's RISING"             -> a concept's rows across week_start; rank_change,
--                                  mention_share_change and is_rising are the signals
--
-- EVERY WEEK HERE IS A COMPLETE WEEK. The weekly export lands mid-week, so the
-- calendar week in progress is usually a fragment — and a fragment can't be ranked
-- against a whole week. int_social_concept_trends therefore doesn't compute it until
-- it finishes, so max(week_start) is always a finished week and "this week's
-- trending items" is never half-counted. The in-progress week shows up next run.
--
-- TWO CLASSES, ranked separately (concept_class):
--   'dish' — Som Tam, Pho, banh khot: what people talk about
--   'item' — Tiparos fish sauce, canned coconut milk, tom yum paste: SELLABLE
--            products a grocery or restaurant could order as a line item. Raw
--            commodities (durian, matcha, pork) are deliberately NOT here — they
--            name a food, not a thing to buy.
-- Each class has its own 1..N per week, so a flood of viral dishes can no longer
-- mask the item-level signal that actually maps to inventory. Show both. Expect the
-- item board to be much thinner — people post about dishes far more than SKUs.
--
-- Per trending thing it answers:
--   1. what's trending, how hard, and is it moving  (rank, mentions, score, mention_share, rank_change)
--   2. where to see it                              (source_links)
--   3. do we carry it                               (result_type + matched item + current stock)
--   4. if not, what similar to offer                (recommended_items)
--   5. what to DO                                   (action_signal)
--
-- TRAJECTORIES ARE COMPLETE, NOT TOP-N-FILTERED. Rows are kept for every week of
-- any concept that reached the top N in ANY week (is_top_n flags the weeks it was
-- actually on the board), because a chart filtered to top-N only would draw a line
-- with holes wherever the concept dipped out. One honest gap remains: a week where
-- the concept fell below social_trend_min_mentions has no upstream row at all, so
-- that week is genuinely missing rather than zero — more common at a 7-day grain
-- than over a multi-week window. If charts look ragged, the fix is dropping the
-- noise floor upstream and keeping it as a board-only filter.
--
-- Lineage: int_social_concept_trends (deterministic per-week ranking +
-- source_links) LEFT JOIN stg_mentionlytics__concept_resolution (offline LLM
-- concept->SKU) LEFT JOIN int_jdawms_items_active (name) LEFT JOIN
-- int_jdawms_stock_weekly (CURRENT stock — the latest snapshot week per item).
-- dbt never calls the LLM.
--
-- CONFIDENCE FLOOR (social_resolve_min_confidence) applies to ANY match — carried,
-- substitute, or basket. Inventory match wins, but only when the match is actually
-- confident: a low-confidence carried match (sushi -> corn oil @0.45) is a bad
-- guess, not a real inventory hit, so it's suppressed just like a shaky basket
-- (row shows 'none' / source_new). Confident carried matches (FZ BANH MI @0.95)
-- still show and outrank baskets. Since the resolver's v5 two-pass design the
-- floor gates a VERIFIED confidence (a second, independent model's calibrated
-- certainty in the items that survived its review), not the proposing model's
-- self-rating — which used to cluster just above the floor and made it inert.

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
        canonical_key,
        alias_of,
        concept_type,
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
        b.week_of_year,
        b.year_week,

        coalesce(r.canonical_label, b.concept_norm)                     as concept_label,
        -- concept_type is the LLM's item-level opinion (dish/category/ingredient/
        -- product/brand) falling back to the ranking class; concept_class is the
        -- hard fact — which of the two boards this row belongs to. Keep both: only
        -- the class can drive "top N per class".
        coalesce(r.concept_type, b.concept_class)                       as concept_type,
        -- same dish under two concept keys (som tam / ส้มตำ — fold_concept merges
        -- Latin diacritics only, never cross-script) shares one canonical_key, and
        -- the resolver harmonises them onto the better-grounded answer. Both rows
        -- still occupy a slot on the board; alias_of says which one is the copy so
        -- a viewer can collapse them.
        r.canonical_key,
        r.alias_of,
        b.trend_rank,
        b.prev_week_start,
        b.prev_trend_rank,
        b.rank_change,
        b.mention_count,
        b.prev_mention_count,
        b.mention_count_wow_pct,
        b.mention_share,
        b.mention_share_change,
        b.total_engagement,
        b.total_views,
        b.trend_score,
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
    j.concept_type,
    j.is_top_n,

    -- the calendar week this row covers, and how much of it we hold data for.
    -- year_week ("2026-W34") is the display label; week_of_year is the bare ISO
    -- number for an axis; week_start is the real date to sort and join on.
    j.week_end,
    j.week_of_year,
    j.year_week,


    -- social trend signal
    j.trend_rank,
    j.mention_count,
    j.mention_share,
    j.total_engagement,
    j.total_views,
    j.trend_score,
    j.source_links,
    j.distinct_authors_adj,
    j.author_quality,
    j.is_single_channel,

    -- movement. rank_change is POSITIVE when the concept moved UP the board;
    -- mention_share_change is the volume-neutral one (see int_social_concept_trends
    -- on why is_rising alone can't be trusted). Nulls mean "no comparison exists",
    -- not "flat".
    j.prev_week_start,
    j.prev_trend_rank,
    j.rank_change,
    j.prev_mention_count,
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
    j.canonical_key,
    j.alias_of,
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
