-- int_search_queries — ONE ROW PER SEARCH A PERSON TYPED. The query grain.
--
-- 258,852 search events, of which 195,249 are customers typing into the website
-- or an app (measured 2026-10-12). Nothing in this warehouse read them until now.
--
-- ═══ WHY THIS IS WORTH HAVING ══════════════════════════════════════════════
-- Social listening tells you what the market is talking about — 318,832 mentions
-- from the public internet, almost none of it from anyone who buys from us. This
-- is the opposite: every row is an account we invoice, typing what they want,
-- into our own search box. Social is reach; this is intent, and it carries
-- customer_key so it can be tied to an account, a rep and a territory.
--
-- It is also the WIDER vocabulary. 3,675 terms were searched by three or more
-- accounts in a quarter, against 364 concepts the social resolver has ever
-- named. Where the two agree you have corroboration; where they disagree, search
-- is usually the one that knows your customers: 'rice' resolved to `none` in the
-- social pipeline and 25 accounts searched it in four weeks.
--
-- ═══ FILTERED ON THE DICTIONARY, NOT ON A CODE RANGE ═══════════════════════
-- l1_category_name = 'Search' comes from seed_event_codes, so a new search
-- screen is picked up when the dictionary learns it. The codes happen to be
-- 12xxxxxx today; hard-coding that range would quietly miss the next one and
-- would break the moment someone renumbers.
--
-- ═══ READS int_events_decoded, NOT int_events_enriched, AND MUST ══════════
-- Enriched is the natural home for this -- it already joins the dictionary and
-- the app registry, which is exactly what this model needs. It also throws away
-- 144,625 of the 247,417 search events, and every one of them is a customer:
--
--   sales_code = '000'    112,697 search events, ALL actor_type = customer
--   sales_code is null     28,258 more
--
-- Its filter is `where e.sales_code not in ('000')`. '000' is the code a
-- customer-originated event carries, so the clause removes most customer
-- activity outright; and because `null not in ('000')` is NULL rather than TRUE
-- in SQL, every null-rep row goes with it. Measured on Web that is 113,258 of
-- 161,906 searches gone, and on Vegas-I all 28,110.
--
-- That is the right filter for a model about REPS, which is what enriched is
-- for -- 312,687 of 3,953,160 events warehouse-wide carry a null sales_code.
-- It is the wrong filter for a model about CUSTOMERS, so this one reads the
-- decoded spine and joins the two seeds itself. The duplication is deliberate
-- and is cheaper than a customer-demand table that silently omits two thirds of
-- the customers.
--
-- ═══ WHAT COUNTS AS A SEARCH, AND WHAT IS THROWN AWAY ══════════════════════
-- Only events whose dictionary entry promises a payload (expected_payload_format
-- = 'bare_value') and that actually carry one. 'Show Search' and the like open a
-- box without typing anything and are correctly absent.
--
-- TERMS BEGINNING WITH A DIGIT ARE FLAGGED, NOT DROPPED. A large block of
-- searches are a SKU number pasted with its full item name --
-- '11051 white corn on the cob 2pc', 280 hits from 8 accounts; '34500 yeos
-- chrysanthemum tea', 260 hits from ONE. That is someone re-ordering from a
-- sheet, not demand discovery, and it swamps any term ranking by volume. It is
-- real behaviour though, and it says which items people re-order by code, so it
-- is marked is_sku_paste rather than deleted and the consumer chooses.
--
-- ONE PERSON TYPING IS NOT A TREND. Count DISTINCT ACCOUNTS, never rows. The two
-- disagree violently: 'mama' is 56 searches from 20 accounts, while a single
-- pasted SKU can be 260 searches from one. Every aggregate downstream leads on
-- account breadth for that reason.
--
-- ═══ FIVE ROWS HAVE IMPOSSIBLE TIMESTAMPS ═════════════════════════════════
-- Two in 1975 and three between 7570 and 7635, out of 258,852. Dropped here
-- rather than downstream, because a 7635 row silently becomes the max() of any
-- window it lands in. The cutoff is the event log's own go-live, so a future
-- backfill of genuinely older events is not excluded by accident.
--
-- NO SEARCH RESULT IS RECORDED. The log says what was typed and nothing about
-- what came back, or whether anything was ordered afterwards. "Nobody found it"
-- cannot be measured from here — only "somebody looked", which is why nothing in
-- this model is named anything like unmet_demand.

{{ config(materialized='view') }}

with events as (

    select
        e.entity_id,
        e.event_at_utc,
        e.customer_key,
        e.username,
        e.sales_code,
        e.actor_type,
        e.source_code,
        e.description_code,
        e.response,
        a.app_name,
        a.platform                                                           as app_platform,
        a.user_type                                                          as app_user_type,
        c.function_name                                                      as feature_name
    from {{ ref('int_events_decoded') }} as e
    inner join {{ ref('seed_event_codes') }} as c
        on c.description_code = e.description_code
    left join {{ ref('seed_app_sources') }} as a
        on a.source_code = e.source_code
    where c.l1_category_name = 'Search'
      -- the dictionary says this code carries what the user typed
      and c.payload_format = 'bare_value'
      and nullif(trim(cast(e.response as {{ dbt.type_string() }})), '') is not null

),

cleaned as (

    select
        entity_id                                                            as event_id,
        event_at_utc,
        cast(event_at_utc as date)                                           as search_date,
        customer_key,
        username,
        sales_code,
        actor_type,
        app_name,
        source_code,
        app_platform,
        app_user_type,
        feature_name,
        description_code,

        -- WHAT WAS TYPED, folded for grouping only. The raw string is kept beside
        -- it: a term is user input and downstream wants to display it as typed.
        nullif(trim(cast(response as {{ dbt.type_string() }})), '')          as search_text,
        lower(trim(cast(response as {{ dbt.type_string() }})))               as search_term,

        length(trim(cast(response as {{ dbt.type_string() }})))              as search_length,

        -- ── the two channels the business asks for separately ─────────────
        -- 'Web' is the website; everything else is a handheld or tablet app.
        -- From seed_app_sources, so a new app lands in the right bucket without
        -- editing this.
        (app_platform = 'Web')                                               as is_web,
        (app_platform is not null and app_platform <> 'Web')                 as is_app,

        -- WHO is typing. Reps searching while they build an order is a different
        -- signal from a customer hunting on the website, and the apps carry both:
        -- PDA and CatalogFS are Sales, Vegas and CatalogFC are Customer.
        (app_user_type = 'Customer')                                         as is_customer_search,
        (app_user_type = 'Sales')                                            as is_rep_search,

        -- ── re-order behaviour, not demand discovery. See the header ──────
        -- A character comparison, NOT a regex: `rlike` is Databricks-only and
        -- DuckDB spells it regexp_matches, so the obvious '^[0-9]' fails the dev
        -- build. "Starts with a digit" needs no regex on either engine.
        (substr(trim(cast(response as {{ dbt.type_string() }})), 1, 1)
             between '0' and '9')                                            as is_sku_paste
    from events

)

select
    *,
    -- a search term worth ranking: typed words, not a pasted code, and long
    -- enough to mean something. Published as a flag so a consumer can widen it
    -- rather than re-deriving the rule.
    (not is_sku_paste and search_length between 3 and 30)                    as is_rankable
from cleaned
-- See the header: five rows out of 258,852 carry impossible timestamps and one
-- of them would become the max() of any window it fell into.
where search_date >= '{{ var("event_log_go_live_date") }}'
  and search_date <= current_date()
