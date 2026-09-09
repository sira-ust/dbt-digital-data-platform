-- DQ audit of concepts the resolver did NOT call 'carried' even though one of its
-- own recommendations is named after the concept. One row per (concept, SKU).
--
-- WHY IT EXISTS. Until PROMPT_VERSION v10 the reviewer could reject a candidate but
-- not re-file one: result_type could only reach 'carried' if pass ① had already set
-- matched_prtnum, so a recommendation that WAS the trending thing stayed a
-- substitute. 'vietnamese coffee' resolved to VIETNAMESE INSTANT COFFEE(100) as a
-- substitute (2026-09-02) and the board told the sales team to offer an alternative
-- to a SKU with 8k units on the shelf. This view is the regression check for that:
-- it stays non-empty by design, so read it as a REVIEW QUEUE, not a pass/fail.
--
-- EXPECT LEGITIMATE ROWS. Name containment cannot tell a finished good from an
-- input to it, and the input cases are correctly NOT carried:
--   'banh xeo'  -> BOT BANH XEO (PREPARED FLOUR)   batter FOR banh xeo
--   'sushi'     -> DF SUSHI GINGER (SLICED)        condiment beside sushi
--   'pho'       -> DF (S) BEEF PASTE (PHO BO)      one component of pho
-- looks_like_input flags those heuristically so a reviewer can sort them last. It
-- is a HINT, not a verdict — judge from item_name, which is the authoritative
-- catalog name, never the LLM's claimed one.
--
-- Token matching, not substring: normalize_item_name pads and upper-cases, so
-- `like '% TOK %'` cannot match COCONUT inside 'DE COCO'. See macros/name_tokens.sql.

with resolution as (

    select
        concept_norm,
        canonical_label,
        result_type,
        match_confidence,
        recommended_prtnums
    from {{ ref('stg_mentionlytics__concept_resolution') }}
    where result_type in ('substitute', 'basket', 'none')
      and recommended_prtnums is not null

),

items as (

    select prtnum, item_name from {{ ref('int_jdawms_items_active') }}

),

-- explode prtnums only and take the name from the master, the same way
-- mart_social_trending_items builds rec_verified — the two arrays are positionally
-- aligned but there is no need to rely on that here.
rec as (

    select
        r.concept_norm,
        {{ unnest('r.recommended_prtnums') }}                            as rec_prtnum
    from resolution as r

),

pairs as (

    select distinct
        r.concept_norm,
        r.canonical_label,
        r.result_type,
        r.match_confidence,
        e.rec_prtnum                                                    as prtnum,
        i.item_name
    from rec as e
    inner join resolution as r
        on r.concept_norm = e.concept_norm
    inner join items as i
        on i.prtnum = e.rec_prtnum

),

-- every word of the concept, long enough to be meaningful
concept_tokens as (

    select concept_norm, token
    from (
        select
            concept_norm,
            {{ unnest("split(" ~ normalize_item_name('concept_norm') ~ ", ' ')") }}
                                                                        as token
        from resolution
    )
    where length(token) >= 3

),

-- a pair fails the containment test the moment ONE concept token is missing from
-- the item name, so count the misses rather than trying to express "all" directly
misses as (

    select
        p.concept_norm,
        p.prtnum,
        count_if({{ normalize_item_name('p.item_name') }} not like concat('% ', t.token, ' %'))
                                                                        as missing_tokens,
        count(*)                                                        as concept_tokens
    from pairs as p
    inner join concept_tokens as t
        on t.concept_norm = p.concept_norm
    group by 1, 2

)

select
    p.concept_norm,
    p.canonical_label,
    p.result_type,
    p.match_confidence,
    p.prtnum,
    p.item_name,
    m.concept_tokens,
    -- HINT only: an item whose name carries one of these is usually an input to the
    -- concept rather than the concept itself. Kept as a flag so the row still shows.
    (   {{ normalize_item_name('p.item_name') }} like '% BOT %'
     or {{ normalize_item_name('p.item_name') }} like '% MIX %'
     or {{ normalize_item_name('p.item_name') }} like '% PASTE %'
     or {{ normalize_item_name('p.item_name') }} like '% FLOUR %'
     or {{ normalize_item_name('p.item_name') }} like '% SEASONING %'
     or {{ normalize_item_name('p.item_name') }} like '% POWDER %'
     or {{ normalize_item_name('p.item_name') }} like '% STOCK %'
     or {{ normalize_item_name('p.item_name') }} like '% SAUCE %'
    )                                                                   as looks_like_input
from pairs as p
inner join misses as m
    on m.concept_norm = p.concept_norm
   and m.prtnum       = p.prtnum
where m.missing_tokens = 0
order by looks_like_input, m.concept_tokens desc, p.concept_norm, p.prtnum
