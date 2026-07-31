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
-- CONFIDENCE FILTER: a match the model was unsure about (match_confidence <
-- social_resolve_min_confidence, ANY result_type) is suppressed — matched item +
-- recommendations dropped, shown as 'none' / source_new — so a shaky match never
-- reaches marketing.

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
        t.trend_score,
        t.net_sentiment,
        t.is_rising,
        t.source_links,
        r.result_type                                                   as raw_result_type,
        r.matched_prtnum                                                as raw_matched_prtnum,
        r.recommended_prtnums,
        r.recommended_item_names,
        r.match_confidence,
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

    -- recommendations (dropped when the match was low-confidence)
    case when a._low_conf then null else a.recommended_prtnums end      as recommended_prtnums,
    case when a._low_conf then null else a.recommended_item_names end   as recommended_items,
    case when a._low_conf then null else a.match_confidence end         as match_confidence,

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
