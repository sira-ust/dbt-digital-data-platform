{{ config(tags=['social']) }}
-- mart_social_trending_items — the marketing-facing trending-item board. A
-- CURRENT-WEEK SNAPSHOT: the top social_trend_top_n concepts of the LATEST week
-- only (period_start = Monday-start ISO week), so it is always ~social_trend_top_n
-- rows. The weekly job recomputes and REPLACES it each run (full-refresh table);
-- it does NOT accumulate history — the ranking history lives in
-- int_social_concept_trends (which momentum needs). Per trending thing it answers:
--   1. what's trending, and how hard  (rank, mentions, score, sentiment)
--   2. where to see it                (source_links — loudest posts)
--   3. do we carry it                 (result_type + matched item + this-week stock)
--   4. if not, what similar to offer  (recommended_items)
--   5. what to DO                     (action_signal)
--
-- Lineage: int_social_concept_trends (deterministic ranking + source_links) LEFT
-- JOIN stg_mentionlytics__concept_resolution (offline LLM concept->SKU) LEFT JOIN
-- int_jdawms_items (authoritative name) LEFT JOIN int_jdawms_stock_weekly (stock,
-- same week). dbt never calls the LLM. A concept the LLM hasn't scored stays as
-- result_type 'unresolved' (visible gap, not a silent drop).
--
-- CONFIDENCE FILTER: a match the model was unsure about (match_confidence <
-- social_resolve_min_confidence, ANY result_type) is suppressed — the matched
-- item and recommendations are dropped and the row shows as 'none' / source_new.
-- Better to show a trending item as "not confidently matched, look into it" than
-- to put a shaky match (french fries -> corn oil @0.35) in front of marketing.
-- Applied here (deterministic, tunable) so it can be retuned without the LLM.
-- Matched-item stock is looked up on the SAME week (CABOT warehouse only).

with trends as (

    -- top-N of the LATEST week only — this is a current-week snapshot
    select *
    from {{ ref('int_social_concept_trends') }}
    where period_start = (select max(period_start) from {{ ref('int_social_concept_trends') }})
      and trend_rank <= {{ var('social_trend_top_n') }}

),

resolution as (

    select * from {{ ref('stg_mentionlytics__concept_resolution') }}

),

items as (

    select prtnum, item_name, item_family
    from {{ ref('int_jdawms_items') }}

),

stock as (

    select
        prtnum,
        week_start,
        max(in_stock)                                                   as in_stock,
        sum(shippable_qty)                                              as shippable_qty
    from {{ ref('int_jdawms_stock_weekly') }}
    group by 1, 2

),

joined as (

    select
        t.period_start,
        t.concept_norm,
        coalesce(r.canonical_label, t.concept_norm)                     as concept_label,
        coalesce(r.concept_type, t.concept_source)                      as concept_type,
        t.trend_rank,
        t.mention_count,
        t.trend_score,
        t.net_sentiment,
        t.source_links,
        r.result_type                                                   as raw_result_type,
        r.matched_prtnum                                                as raw_matched_prtnum,
        r.recommended_prtnums,
        r.recommended_item_names,
        r.match_confidence,
        -- suppress any match the model was not confident about (all result types)
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
        -- null the matched SKU when suppressed, so the item/stock joins drop out
        case when _low_conf then null else raw_matched_prtnum end        as matched_prtnum
    from joined

)

select
    -- weekly snapshot: surrogate key = week | concept
    a.period_start || '|' || a.concept_norm                            as concept_key,

    a.period_start,
    a.concept_label,
    a.concept_norm,
    a.concept_type,

    -- social trend signal
    a.trend_rank,
    a.mention_count,
    a.trend_score,
    a.net_sentiment,
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
    on  st.prtnum = a.matched_prtnum
    and st.week_start = a.period_start
