{{ config(tags=['social']) }}
-- mart_social_trending_items — the marketing-facing "currently trending" board. A
-- SINGLE CURRENT SNAPSHOT: the top social_trend_top_n concepts over the trailing
-- social_trend_window_weeks window (see int_social_concept_trends), so it is always
-- ~social_trend_top_n rows and a sustained trend KEEPS SHOWING until it fades out
-- of the window. Recomputed and REPLACED each run; no per-week history. Per
-- trending thing it answers:
--   1. what's trending, how hard, and is it rising  (rank, mentions, score, is_rising)
--   2. where to see it                              (source_links)
--   3. do we carry it                               (result_type + matched item + current stock)
--   4. if not, what similar to offer                (recommended_items)
--   5. what to DO                                   (action_signal)
--
-- Lineage: int_social_concept_trends (deterministic window ranking + source_links)
-- LEFT JOIN stg_mentionlytics__concept_resolution (offline LLM concept->SKU) LEFT
-- JOIN int_jdawms_items (name) LEFT JOIN int_jdawms_stock_weekly (CURRENT stock —
-- the latest snapshot week per item). dbt never calls the LLM.
--
-- CONFIDENCE FLOOR (social_resolve_min_confidence) applies to ANY match — carried,
-- substitute, or basket. Inventory match wins, but only when the match is actually
-- confident: a low-confidence carried match (sushi -> corn oil @0.45) is a bad
-- guess, not a real inventory hit, so it's suppressed just like a shaky basket
-- (row shows 'none' / source_new). Confident carried matches (FZ BANH MI @0.95)
-- still show and outrank baskets.

with trends as (

    -- already a current-window snapshot; just take the top N
    select *
    from {{ ref('int_social_concept_trends') }}
    where trend_rank <= {{ var('social_trend_top_n') }}

),

resolution as (

    select * from {{ ref('stg_mentionlytics__concept_resolution') }}

),

items as (

    select prtnum, item_name, item_family
    from {{ ref('int_jdawms_items') }}

),

-- CURRENT stock: the latest snapshot week per item (roll wh/client up first)
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

joined as (

    select
        t.window_start,
        t.window_end,
        t.concept_norm,
        coalesce(r.canonical_label, t.concept_norm)                     as concept_label,
        coalesce(r.concept_type, t.concept_source)                      as concept_type,
        t.trend_rank,
        t.mention_count,
        t.total_engagement,
        t.total_views,
        t.trend_score,
        t.net_sentiment,
        t.is_rising,
        t.source_links,
        r.result_type                                                   as raw_result_type,
        r.matched_prtnum                                                as raw_matched_prtnum,
        r.recommended_prtnums,
        r.recommended_item_names,
        r.match_confidence,
        -- floor applies to ANY match (carried / substitute / basket): inventory
        -- wins, but only when the match is actually confident. A low-confidence
        -- carried match is a bad guess (sushi -> corn oil @0.45), not a real
        -- inventory hit, so it's suppressed just like a shaky basket.
        r.result_type in ('carried', 'substitute', 'basket')
            and coalesce(r.match_confidence, 0)
                < {{ var('social_resolve_min_confidence') }}            as _low_conf
    from trends as t
    left join resolution as r
        on r.concept_norm = t.concept_norm

),

adjusted as (

    select
        *,
        case when _low_conf then 'none' else raw_result_type end        as result_type_adj,
        case when _low_conf then null else raw_matched_prtnum end        as matched_prtnum
    from joined

),

-- VERIFY recommendations against the real item master. The resolver stores the
-- LLM's self-reported prtnum+name pairs unchecked, so a hallucinated SKU or a
-- name that doesn't match its prtnum can slip through (matched_item_name is
-- already verified via the items join; recommendations were not). Explode, inner
-- join to int_jdawms_items — dropping any prtnum that isn't a real SKU — and take
-- the AUTHORITATIVE name from the master, never the LLM's claimed name.
rec_exploded as (

    select
        a.concept_norm,
        {{ unnest('a.recommended_prtnums') }}                           as rec_prtnum
    from adjusted as a
    where not a._low_conf
      and a.recommended_prtnums is not null

),

rec_verified as (

    select re.concept_norm, re.rec_prtnum, itm.item_name
    from rec_exploded as re
    inner join items as itm
        on itm.prtnum = re.rec_prtnum

),

rec_agg as (

    select
        concept_norm,
        array_agg(rec_prtnum)                                          as recommended_prtnums,
        array_agg(item_name)                                           as recommended_items
    from rec_verified
    group by 1

)

select
    a.window_start,
    a.window_end,
    a.concept_label,
    a.concept_norm,
    a.concept_type,

    -- social trend signal
    a.trend_rank,
    a.mention_count,
    a.total_engagement,
    a.total_views,
    a.trend_score,
    a.net_sentiment,
    a.is_rising,
    a.source_links,

    -- do we carry it? (unresolved = the gate hasn't scored this concept yet)
    coalesce(a.result_type_adj, 'unresolved')                          as result_type,
    a.matched_prtnum,
    itm.item_name                                                      as matched_item_name,
    st.in_stock,
    st.shippable_qty,

    -- recommendations: only real SKUs (verified against the item master), shown
    -- with their authoritative names; dropped when the match was low-confidence
    ra.recommended_prtnums,
    ra.recommended_items,
    -- only meaningful when there's an actual match shown; null for none/unresolved
    -- (a confidence score on a "no match" is noise)
    case when a.result_type_adj in ('carried', 'substitute', 'basket')
         then a.match_confidence end                                    as match_confidence,

    -- what marketing should do
    case
        when a.result_type_adj = 'carried'    and coalesce(st.in_stock, 0) = 1 then 'promote_now'
        when a.result_type_adj = 'carried'    and coalesce(st.in_stock, 0) = 0 then 'restock'
        when a.result_type_adj = 'substitute'                                  then 'offer_substitute'
        when a.result_type_adj = 'basket'                                      then 'promote_ingredients'
        when a.result_type_adj = 'none'                                        then 'source_new'
        else 'monitor'
    end                                                                as action_signal

from adjusted as a
left join items as itm
    on itm.prtnum = a.matched_prtnum
left join stock as st
    on st.prtnum = a.matched_prtnum
left join rec_agg as ra
    on ra.concept_norm = a.concept_norm
