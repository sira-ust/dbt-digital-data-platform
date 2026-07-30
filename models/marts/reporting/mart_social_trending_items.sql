{{ config(tags=['social']) }}
-- mart_social_trending_items — the marketing-facing trending-item board. One row
-- per (period_grain, period_start, concept), kept to the top social_trend_top_n
-- by trend_rank. Answers, per trending thing:
--   1. what's trending on social, and how hard  (rank, mentions, score, sentiment)
--   2. do we carry it                            (result_type + matched item + stock)
--   3. if not, what similar do we recommend      (recommended_items)
--   4. what should marketing DO                  (action_signal)
--
-- Lineage: int_social_concept_trends (deterministic ranking) LEFT JOIN
-- stg_mentionlytics__concept_resolution (offline LLM concept->SKU) LEFT JOIN
-- int_jdawms_items (authoritative name for the matched SKU) LEFT JOIN
-- int_jdawms_stock_weekly (can we ship it, this week). LEFT JOINs throughout: a
-- top concept the gate didn't resolve stays on the board as 'unresolved' rather
-- than vanishing (so the coverage gap is visible, not hidden).
--
-- recommended_items is an ARRAY (a dish -> several ingredient SKUs). It rides
-- through as the LLM's display names; the xlsx export flattens it to text for
-- marketing. Matched-item STOCK is looked up on the SAME week as the trend
-- (weekly grain -> that week; daily grain -> the week containing the day).
--
-- Full-refresh table: the leaderboard re-ranks every run as new mentions land,
-- and it is tiny (top_n rows x periods x 2 grains).

with trends as (

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

-- collapse stock to prtnum x week (staging keys it by prt_client_id / wh_id too,
-- single-valued in practice — mirror mart_item_demand_supply's roll-up)
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
        t.period_grain,
        t.period_start,
        t.concept_norm,
        -- canonical name from the LLM (merges cross-language dupes); fall back to
        -- the raw normalised text until the concept is resolved
        coalesce(r.canonical_label, t.concept_norm)                     as concept_label,
        -- richer item-type from the LLM when resolved, else the ranking source
        coalesce(r.concept_type, t.concept_source)                      as concept_type,
        t.trend_rank,
        t.mention_count,
        t.trend_score,
        t.net_sentiment,
        r.result_type,
        r.matched_prtnum,
        r.recommended_prtnums,
        r.recommended_item_names,
        r.match_confidence,
        -- the ISO week the stock lookup uses: weekly grain is already Monday, so
        -- date_trunc is a no-op there; daily grain maps to its containing week
        cast({{ dbt.date_trunc('week', 't.period_start') }} as date)    as stock_week
    from trends as t
    left join resolution as r
        on r.concept_norm = t.concept_norm

)

select
    -- surrogate key: unique per row (grain + period + concept)
    j.period_grain || '|' || cast(j.period_start as {{ dbt.type_string() }})
        || '|' || j.concept_norm                                        as concept_key,

    j.period_grain,
    j.period_start,
    j.concept_label,
    j.concept_norm,
    j.concept_type,

    -- social trend signal
    j.trend_rank,
    j.mention_count,
    j.trend_score,
    j.net_sentiment,

    -- do we carry it? (unresolved = the gate hasn't scored this concept yet)
    coalesce(j.result_type, 'unresolved')                               as result_type,
    j.matched_prtnum,
    itm.item_name                                                       as matched_item_name,
    st.in_stock,
    st.shippable_qty,

    -- what to recommend (arrays; the export flattens recommended_items to text)
    j.recommended_prtnums,
    j.recommended_item_names                                            as recommended_items,
    j.match_confidence,

    -- what marketing should do
    case
        when j.result_type = 'carried'    and coalesce(st.in_stock, 0) = 1 then 'promote_now'
        when j.result_type = 'carried'    and coalesce(st.in_stock, 0) = 0 then 'restock'
        when j.result_type = 'substitute'                                  then 'offer_substitute'
        when j.result_type = 'basket'                                      then 'promote_ingredients'
        when j.result_type = 'none'                                        then 'source_new'
        else 'monitor'
    end                                                                 as action_signal

from joined as j
left join items as itm
    on itm.prtnum = j.matched_prtnum
left join stock as st
    on  st.prtnum = j.matched_prtnum
    and st.week_start = j.stock_week
