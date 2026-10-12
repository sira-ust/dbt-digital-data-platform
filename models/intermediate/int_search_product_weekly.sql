-- int_search_product_weekly — SEARCHES ROLLED UP TO THE PRODUCT THE BOARD RANKS.
-- One row per (product, week). This is the model the trending board joins to.
--
-- int_search_terms_weekly is the TERM grain and stays the place to read what
-- people actually typed. This is the same searches collapsed onto the product,
-- because the board ranks products: 'mama', 'mama noodle' and 'mama instant
-- noodle' are one row here and three there.
--
-- ═══ WHY THE BOARD CANNOT JUST SUM THE TERM MODEL ══════════════════════════
-- ust_accounts is a DISTINCT COUNT. Summing it across the spellings of one
-- product counts an account once per spelling it tried, and an account hunting
-- for something usually tries more than one. Measured against live data,
-- summing overstates 271 of 8,735 product-weeks, and the error is proportionally
-- worst exactly where the number is small enough to matter:
--
--     spring rolls  2026-09-14   3 spellings   summed 4   true 2
--     pho           2026-07-20   4 spellings   summed 10  true 8
--
-- A doubled account count on a thinly-searched product is the difference
-- between "two customers asked" and "four customers asked", which is the
-- difference between ignoring it and sourcing it. The distinct count has to be
-- taken once, over the whole product, which is what this model exists to do.
-- Searches and users are plain sums and would have been safe; the account count
-- is the one that is not, and it is the one the business ranks on.
--
-- ═══ THE SAME 2x BRIDGE FAN-OUT AS THE TERM MODEL ══════════════════════════
-- int_social_concept_canon is keyed on (concept_class, concept_norm), so a name
-- on both the dish and item boards has two rows pointing at one product. Joining
-- on concept_norm alone doubles every search row — it doubled the term model's
-- first draft and nothing looked wrong, because the number was merely bigger.
-- The deduped bridge is rebuilt here rather than imported, so this model cannot
-- be made wrong by a change to the other one's output shape.
--
-- Names whose two rows disagree about the product (316 of 30,007) resolve to no
-- product and so never reach this model at all. They are visible, with their
-- counts, in int_search_terms_weekly.
--
-- ═══ ONE PRODUCT CAN APPEAR TWICE ON THE BOARD ═════════════════════════════
-- The board is keyed on (concept_class, concept_norm) and the canon map can
-- point two of those at one product — 'fish sauce' and 'น้ำปลา' were two board
-- rows for one product until concept grouping merged them. Both rows will show
-- THESE SAME NUMBERS. That is the honest answer (the searches really are for
-- that one product) but it is duplication on screen, not two populations, and
-- summing a board column down the page would double them.
--
-- ═══ WEEKS HERE ARE NOT THE BOARD'S WEEKS ══════════════════════════════════
-- This covers every week the event log has. The board keeps 13 rolling and is
-- built by a hand-run job, so it ran two weeks behind on 2026-10-12. Join FROM
-- the board and treat a missing search row as zero only inside this model's week
-- range — outside it, zero would mean "we had no search log", which is a very
-- different statement from "nobody searched". week_start/week_end bounds are
-- published for exactly that guard.

{{ config(materialized='table') }}

with queries as (

    select * from {{ ref('int_search_queries') }}
    where is_rankable

),

-- ── the bridge, deduplicated. See the header ──────────────────────────────
concept_bridge as (

    select
        concept_norm,
        case when count(distinct product_key) = 1 then max(product_key) end  as product_key
    from {{ ref('int_social_concept_canon') }}
    group by concept_norm

),

resolved as (

    select
        b.product_key,
        cast({{ dbt.date_trunc('week', 'q.search_date') }} as date)          as week_start,
        q.search_term,
        q.customer_key,
        q.username,
        q.is_web,
        q.is_app,
        q.is_customer_search,
        q.is_rep_search
    from queries as q
    inner join concept_bridge as b
        on b.concept_norm = q.search_term
    where b.product_key is not null

),

-- which spelling people used most, so a board row can say WHY it has searches.
-- Ranked on accounts then searches: the term the most different customers typed
-- is the representative one, not the one somebody repeated loudest.
term_rank as (

    select
        product_key,
        week_start,
        search_term,
        row_number() over (
            partition by product_key, week_start
            order by count(distinct customer_key) desc, count(*) desc, search_term
        )                                                                    as rn
    from resolved
    group by product_key, week_start, search_term

),

rolled as (

    select
        product_key,
        week_start,

        -- ── the channel split the business asks for ───────────────────────
        -- Device, not audience. app_searches is every handheld and tablet and
        -- so mixes reps (PDA, CatalogFS) with customers (Vegas, CatalogFC);
        -- customer_searches / rep_searches below are the audience cut, and the
        -- two are deliberately not crossed.
        sum(case when is_web then 1 else 0 end)                              as web_searches,
        sum(case when is_app then 1 else 0 end)                              as app_searches,
        count(*)                                                             as total_searches,

        sum(case when is_customer_search then 1 else 0 end)                  as customer_searches,
        sum(case when is_rep_search then 1 else 0 end)                       as rep_searches,

        -- ── THE DEMAND NUMBER, counted once over the whole product ────────
        -- See the header: this is the measure that cannot be summed up from
        -- the term grain.
        count(distinct customer_key)                                         as ust_accounts,
        count(distinct username)                                             as distinct_users,
        count(distinct search_term)                                          as distinct_terms
    from resolved
    group by product_key, week_start

)

select
    r.product_key,
    r.week_start,
    {{ dbt.dateadd('day', 6, 'r.week_start') }}                              as week_end,

    t.search_term                                                            as top_search_term,

    r.web_searches,
    r.app_searches,
    r.total_searches,
    r.customer_searches,
    r.rep_searches,

    r.ust_accounts,
    r.distinct_users,
    r.distinct_terms
from rolled as r
left join term_rank as t
       on t.product_key = r.product_key
      and t.week_start  = r.week_start
      and t.rn          = 1
