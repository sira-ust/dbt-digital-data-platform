-- int_search_terms_weekly — ONE ROW PER SEARCH TERM PER WEEK, with the channel
-- split the business asks for and the key that joins to the trending board.
--
--   Week | Term | Web | App | Accounts | Reps | the product it resolves to
--
-- ═══ ACCOUNTS, NOT SEARCHES, IS THE DEMAND NUMBER ══════════════════════════
-- The two disagree violently and the wrong one is the flattering one. 'mama' is
-- 56 searches from 20 accounts; a single pasted SKU line is 260 searches from
-- ONE. Rank on ust_accounts. web_searches and app_searches say how hard people
-- looked, never how many people wanted it.
--
-- ═══ THE JOIN TO THE BOARD GOES THROUGH product_key ════════════════════════
-- mart_social_trending_items stores a CANONICALISED name — 'mama instant
-- noodles' — and customers type 'mama'. Joining search text straight onto the
-- board matches 2 of 20 rows and produces a column of zeros that looks like
-- "nobody searched" rather than "wrong key".
--
-- int_social_concept_canon is the bridge and already exists for exactly this
-- shape of problem: 30,007 names onto 22,552 products. Routing through it takes
-- the match from 54 terms to 418.
--
-- ═══ THE BRIDGE FANS OUT 2x AND IT IS SILENT ═══════════════════════════════
-- int_social_concept_canon is keyed on (concept_class, concept_norm) — ONE ROW
-- PER NAME PER BOARD. A name appearing on both the dish and item boards has two
-- rows, both pointing at the same product:
--
--     dish | mama | mama instant noodles
--     item | mama | mama instant noodles
--
-- Joining on concept_norm alone doubles every search row. It doubled this
-- model's first draft: 'Mama Instant Noodles' reported 75 web searches against a
-- true 38, and nothing looked wrong because the number was merely bigger. Same
-- failure as the dim_items fan-out that turned 200 items into 1,744 rows.
-- 2,122 of 30,007 names carry the duplicate.
--
-- The join therefore reads a DEDUPED bridge. Where the two rows disagree about
-- the product — 316 names, 1% — the name is genuinely ambiguous and is left
-- UNRESOLVED rather than attributed to whichever row sorted first. A term with
-- no product_key still gets its own row and its own counts; it simply does not
-- reach the board. is_ambiguous_concept says which case a null is.
--
-- ═══ WEEKS HERE ARE NOT THE BOARD'S WEEKS ══════════════════════════════════
-- This model covers every week the event log has — 48 of them, from 2025-11-03.
-- The board keeps a 13-week rolling window and is built by a hand-run job, so it
-- was two weeks behind on 2026-10-12. A consumer joining the two MUST treat
-- "no board row" as unknown rather than zero: a zero where the board simply has
-- not been run yet reads as demand vanishing. Join from the board, left, and
-- publish whether the board week existed.

{{ config(materialized='table') }}

with queries as (

    select * from {{ ref('int_search_queries') }}
    where is_rankable

),

-- ── the bridge, deduplicated. See the header ──────────────────────────────
-- One row per name. A name whose two board rows point at different products is
-- kept with a null product_key and flagged, so an ambiguous term is visibly
-- unresolved instead of silently attributed.
concept_bridge as (

    select
        concept_norm,
        case when count(distinct product_key) = 1 then max(product_key) end  as product_key,
        (count(distinct product_key) > 1)                                    as is_ambiguous_concept
    from {{ ref('int_social_concept_canon') }}
    group by concept_norm

),

weekly as (

    select
        cast({{ dbt.date_trunc('week', 'q.search_date') }} as date)          as week_start,
        q.search_term,

        -- ── the channel split, as asked for ───────────────────────────────
        sum(case when q.is_web then 1 else 0 end)                            as web_searches,
        sum(case when q.is_app then 1 else 0 end)                            as app_searches,
        count(*)                                                             as total_searches,

        -- ── WHO. The apps carry both populations, so these are not a split
        --    of the two above: a rep on a PDA counts in app_searches AND in
        --    rep_searches. Published separately rather than crossed, because
        --    the crossing is four columns nobody asked for.
        sum(case when q.is_customer_search then 1 else 0 end)                as customer_searches,
        sum(case when q.is_rep_search then 1 else 0 end)                     as rep_searches,

        -- ── THE DEMAND NUMBER. See the header ─────────────────────────────
        count(distinct q.customer_key)                                       as ust_accounts,
        count(distinct q.username)                                           as distinct_users,
        count(distinct q.sales_code)                                         as distinct_reps,

        -- the term as somebody actually typed it, for display
        max(q.search_text)                                                   as search_text_sample,
        min(q.event_at_utc)                                                  as first_search_at,
        max(q.event_at_utc)                                                  as last_search_at
    from queries as q
    group by 1, 2

)

select
    w.week_start,
    {{ dbt.dateadd('day', 6, 'w.week_start') }}                              as week_end,
    w.search_term,
    w.search_text_sample,

    -- ── what the trending board calls this thing, if it knows it ─────────
    -- NULL means one of two different things and the flag says which: the
    -- social pipeline has never named this concept, or it named it twice and
    -- disagreed with itself.
    b.product_key                                                            as social_product_key,
    coalesce(b.is_ambiguous_concept, false)                                  as is_ambiguous_concept,
    (b.product_key is not null)                                              as reaches_social_board,

    w.web_searches,
    w.app_searches,
    w.total_searches,
    w.customer_searches,
    w.rep_searches,

    w.ust_accounts,
    w.distinct_users,
    w.distinct_reps,

    w.first_search_at,
    w.last_search_at
from weekly as w
left join concept_bridge as b
    on b.concept_norm = w.search_term
