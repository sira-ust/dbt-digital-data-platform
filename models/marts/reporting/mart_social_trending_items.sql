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
--   3. do we carry it                           (result_type + carried_items = EVERY SKU of
--                                                it we stock + current stock)
--   4. if not, what similar to offer            (recommended_items; nearest_items
--                                                when nothing cleared the bar)
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
-- is suppressed like a shaky basket (shown as 'none'). The suppressed SKUs are not
-- thrown away, though — they reappear in nearest_items with action_signal
-- 'review_nearest', so a floored match reads as "look at this" rather than the
-- 'source_new' it used to read as. See nearest_raw. Since the
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
        group_primary,
        group_label,
        result_type                                                     as raw_result_type,
        matched_prtnum                                                  as raw_matched_prtnum,
        recommended_prtnums,
        -- items the verifier LOOKED AT and turned down. Carried through so a 'none'
        -- can still show what was considered — see nearest_agg.
        rejected_prtnums,
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

-- CARRIED SKUS — every SKU of this product we stock, matched item included.
--
-- A 'carried' result is exactly ONE part number, by contract: the resolver returns a
-- scalar matched_prtnum, and reconcile() empties the recommendation list whenever a
-- match survives ("a carried match stands on its own"). So the board answered "Oyster
-- Sauce -> LKK GREEN PANDA OYSTER SAUCE" while we stock 16 oyster sauces including six
-- Dragonfly ones, and a rep reading the row had no way to see them (reported
-- 2026-09-03). The resolution is not wrong — it is just not a list.
--
-- These are NOT alternatives or substitutes, and the first version of this column
-- called them that. "Oyster Sauce" is not a request for one part number that 15 other
-- items could stand in for — we carry oyster sauce, and 16 SKUs are how. The scalar
-- matched_prtnum is an artifact of the resolver's contract, not a statement that one
-- SKU is the real answer; it survives as the REPRESENTATIVE pick (and as what
-- current_in_stock and action_signal are computed from — see the stock CTE). So the
-- list includes it, and leads with it.
--
-- A FLOOR, NOT A CENSUS. Membership is decided on item NAMES, so a SKU that spells the
-- product differently is missed: of the 16 oyster sauces, this finds 12 — the other
-- four write "OYS SCE" for "OYSTER SAUCE" (measured 2026-09-03). Undercounting is the
-- safe direction (every SKU listed really is the product), but do not read the length
-- as "we stock exactly N". The catalog abbreviation seed planned for the resolver's
-- retrieval misses would close most of this gap here too.
--
-- Fixed HERE rather than in the resolver, on purpose. Which SKUs are the same product
-- is a fact about the item master, not a judgment about a social trend: it changes
-- when purchasing adds a size, not when the resolver next runs. Doing it in SQL means
-- a new pack size shows up on the next build with no LLM call, no re-resolve, and no
-- chance of a hallucinated part number.
--
-- THE RULE: an alternate must live in the matched item's item_family AND be
-- describable by the same words. Concretely, take the concept's tokens that the
-- MATCHED item's name actually uses (the "anchor" tokens — catalog vocabulary, so
-- cross-language and abbreviation noise drops out on its own), and require a candidate
-- to carry ALL of them.
--
-- Both halves are load-bearing:
--   * family alone is far too coarse — 0602 is every sauce, 165 items, so oyster sauce
--     would list ABC SWEET SOY SAUCE;
--   * tokens alone cross families — 'oyster' would pull in DF OYSTER MUSHROOM (0304)
--     and FZ BRAISED KING OYSTER MSHRM (1615).
--   * ALL anchor tokens, not the rarest one: ranking tokens by catalog rarity and
--     taking the best picked WATER for 'coconut water' (watermelon drinks) and THAI
--     for 'thai tea'. Requiring every anchor token turns coconut water into exactly
--     the other TAS coconut waters.
--
-- It fails EMPTY, never wrong. A Thai- or Vietnamese-script concept shares no tokens
-- with an English catalog name, so it gets no anchor tokens and no alternates — which
-- is the correct answer here, not a gap to paper over. Same for a product whose
-- siblings are named differently (condensed milk: the creamers do not say MILK).
-- canonical NAME TOKENS for every active item: split the name, drop tokens under three
-- characters (pack sizes and noise; a two-character anchor matches far too much), and
-- expand warehouse shorthand through the seed. Canonicalising here rather than
-- comparing name strings is what lets "LKK PREMIUM OYSTER SCE18OZ(12)" and
-- "DF OYSTER SAUCE(GLASS)" be recognised as the same product.
name_abbreviations as (

    select
        upper(trim(abbreviation))                                       as abbreviation_norm,
        upper(trim(expansion))                                          as expansion_norm
    from {{ ref('seed_jdawms_name_abbreviations') }}
    where coalesce(is_active, true)

),

item_name_tokens as (

    select
        t.prtnum,
        t.item_family,
        t.item_name,
        {{ singularize('coalesce(ab.expansion_norm, t.token)') }}        as token
    from (
        select
            prtnum, item_family, item_name,
            {{ unnest("split(" ~ normalize_item_name('item_name') ~ ", ' ')") }}
                                                                        as token
        from items
    ) as t
    left join name_abbreviations as ab
        on ab.abbreviation_norm = t.token
    where length(t.token) >= 3

),

alt_matched as (

    select
        rf.concept_norm,
        rf.matched_prtnum,
        itm.item_name                                                   as matched_item_name,
        itm.item_family
    from resolution_final as rf
    inner join items as itm
        on itm.prtnum = rf.matched_prtnum
    -- result_type_adj, not raw: a floored match is not a match, so it gets no SKU list
    -- either (it is already surfaced by nearest_raw below)
    where rf.result_type_adj = 'carried'

),

-- the concept's tokens, canonicalised the same way, keeping only those the MATCHED
-- item's own name uses. Catalog vocabulary, so cross-language and spelling noise drops
-- out on its own — a Thai-script concept simply contributes none, and correctly gets
-- no list rather than a wrong one.
alt_anchor_tokens as (

    select distinct
        am.concept_norm,
        am.matched_prtnum,
        am.item_family,
        am.matched_item_name,
        ct.token
    from (
        select
            t.concept_norm,
            {{ singularize('coalesce(ab.expansion_norm, t.token)') }}    as token
        from (
            select
                concept_norm,
                {{ unnest("split(" ~ normalize_item_name('concept_norm') ~ ", ' ')") }}
                                                                        as token
            from alt_matched
        ) as t
        left join name_abbreviations as ab
            on ab.abbreviation_norm = t.token
        where length(t.token) >= 3
    ) as ct
    inner join alt_matched as am
        on am.concept_norm = ct.concept_norm
    inner join item_name_tokens as mt
        on mt.prtnum = am.matched_prtnum
       and mt.token  = ct.token

),

alt_token_counts as (

    select concept_norm, count(distinct token) as n_anchor_tokens
    from alt_anchor_tokens
    group by 1

),

-- every SKU in the matched item's family carrying EVERY anchor token — the matched
-- item INCLUDED, since it is one of the SKUs we carry, not something the others are
-- alternatives to. Equality on canonical tokens, never a LIKE over the raw name: a
-- substring test matched 'coconut water' against MOGU WATERMELON NATA DE COCO through
-- WATER, and could not see SCE and SAUCE as the same word.
alt_hits as (

    select
        anch.concept_norm,
        cand.prtnum,
        cand.item_name,
        -- BRAND PROXY: the leading token of the item name. The master is written
        -- brand-first ("LKK OYSTER SAUCE 32 OZ", "MAEKRUA OYSTER SCE(THAI) (M)"), so
        -- this is right far more often than not, and the cost of it being wrong is a
        -- slightly worse ORDER — never a wrong item, because membership is decided
        -- entirely by family + tokens. split_part on the space-padded name, not an
        -- array subscript: DuckDB arrays are 1-indexed and Databricks' are 0-indexed,
        -- and split_part sidesteps that (verified on both, 2026-09-03). Part 2, because
        -- the padding makes part 1 the empty string.
        split_part({{ normalize_item_name('cand.item_name') }}, ' ', 2)  as brand_token,
        split_part({{ normalize_item_name('anch.matched_item_name') }}, ' ', 2)
                                                                        as matched_brand_token,
        -- the resolver's representative pick, kept at the head of the list
        max(case when cand.prtnum = anch.matched_prtnum then 1 else 0 end) as is_matched,
        count(distinct anch.token)                                        as n_matched_tokens
    -- `anch`, not `at`: AT is a reserved word on DuckDB (time-travel syntax) and the
    -- alias fails to parse there while compiling fine on Databricks
    from alt_anchor_tokens as anch
    inner join item_name_tokens as cand
        on cand.item_family = anch.item_family
       and cand.token       = anch.token
    group by 1, 2, 3, 4, 5

),

-- one row per distinct item NAME (the duplicate-prtnum collapse rec_verified and
-- nearest_verified both make), keeping the matched part number specifically so a name
-- the master holds twice (DRAGONFLY THAI JASMINE RICE 26 sits on two prtnums) resolves
-- to the one the resolver actually named rather than whichever sorts lower.
--
-- NOT TRUNCATED. The list answers "what do we carry", so cutting it made the answer
-- WRONG rather than short — we stock 16 oyster sauces and a five-item cap implied six.
-- social_carried_skus_max survives only as a runaway guard, set far above any real
-- product family; carried_sku_count is the number to read, and
-- assert_social_carried_skus_aligned fails if the guard ever actually bites.
alt_ranked as (

    select concept_norm, prtnum, item_name
    from (
        -- ONE PER BRAND FIRST, then second-best per brand, and so on. Ordering by part
        -- number alone clusters by brand, because the master assigns them in blocks —
        -- oyster sauce filled its first five slots with LKK (20001-20016) and never
        -- reached Dragonfly (21519-21526), which is precisely the question this column
        -- exists to answer. _brand_rn is the round, so the list rotates across brands;
        -- within a round, a brand OTHER than the matched item's comes first. The
        -- matched item leads the whole list.
        select
            d.concept_norm,
            d.prtnum,
            d.item_name,
            row_number() over (
                partition by d.concept_norm
                order by d.is_matched desc,
                         d._brand_rn,
                         case when d.brand_token = d.matched_brand_token then 1 else 0 end,
                         coalesce(st.in_stock, 0) desc,
                         d.prtnum
            )                                                          as _pick_rn
        from (
            select
                concept_norm, prtnum, item_name, brand_token, matched_brand_token, is_matched,
                row_number() over (
                    partition by concept_norm, brand_token
                    order by is_matched desc, in_stock desc, prtnum
                )                                                      as _brand_rn
            from (
                select
                    h.concept_norm,
                    h.prtnum,
                    h.item_name,
                    h.brand_token,
                    h.matched_brand_token,
                    h.is_matched,
                    coalesce(bst.in_stock, 0)                          as in_stock,
                    row_number() over (
                        partition by h.concept_norm, h.item_name
                        order by h.is_matched desc, h.prtnum
                    )                                                  as _name_rn
                from alt_hits as h
                inner join alt_token_counts as tc
                    on tc.concept_norm    = h.concept_norm
                   and tc.n_anchor_tokens = h.n_matched_tokens
                left join stock as bst
                    on bst.prtnum = h.prtnum
            )
            where _name_rn = 1
        ) as d
        left join stock as st
            on st.prtnum = d.prtnum
    )
    where _pick_rn <= {{ var('social_carried_skus_max') }}

),

-- Both array_agg()s in ONE aggregate — same single-pass argument as rec_agg, asserted
-- by tests/assert_social_carried_skus_aligned.sql.
carried_sku_agg as (

    select
        concept_norm,
        array_agg(prtnum)                                              as carried_prtnums,
        array_agg(item_name)                                           as carried_items,
        count(*)                                                       as carried_sku_count
    from alt_ranked
    group by 1

),

-- NEAREST ITEMS — what to show when result_type lands on 'none'.
--
-- 'none' used to mean an empty row and action_signal 'source_new': "go and source
-- this". That is the most expensive wrong answer the board can give, because it sends
-- the sales team out for something already in the warehouse. Two ways a concept reaches
-- 'none' while the resolver DID find real, active SKUs:
--
--   1. the verifier turned every candidate down. It stores what it rejected AND why
--      (rejected_prtnums / rejected_reasons), so the items are known. Observed
--      2026-08-30, "yogurt": 73116 FZ CHEESE YOGURT rejected as "frozen cheese yogurt
--      is a processed, packaged product ... mentions show fresh yogurt drinks/bowls" —
--      a defensible call that still ended in "source yogurt" while we stock it.
--   2. the confidence floor suppressed the match wholesale (_low_conf). Observed the
--      same run, "som tam": a basket of DF (WHOLE) RED CHILI at 0.35 verified
--      confidence, floored to 'none'.
--
-- Both are "we found something, we are NOT confident it is the answer". So they are
-- surfaced in their OWN columns, never in recommended_*, and the action becomes
-- 'review_nearest' rather than 'source_new'. The floor and the verifier are both left
-- exactly as they are — this changes what the row SHOWS, not what it BELIEVES.
--
-- The two sources are disjoint by construction: _low_conf is only ever true for
-- carried/substitute/basket, so a raw 'none' can never also be a suppressed match.
nearest_raw as (

    select
        concept_norm,
        {{ unnest('rejected_prtnums') }}                                 as nearest_prtnum
    from resolution_final
    where raw_result_type = 'none'
      and rejected_prtnums is not null

    union all

    -- a suppressed match: the item the resolver actually named
    select
        concept_norm,
        raw_matched_prtnum                                              as nearest_prtnum
    from resolution_final
    where _low_conf
      and raw_matched_prtnum is not null

    union all

    -- ...and its suppressed basket/substitute list
    select
        concept_norm,
        {{ unnest('recommended_prtnums') }}                              as nearest_prtnum
    from resolution_final
    where _low_conf
      and recommended_prtnums is not null

),

-- Same verification rec_verified applies, for the same reasons: the resolver stores
-- what the LLM returned, so drop anything that is not a real ACTIVE SKU, take the
-- name from the master, and collapse the duplicate-name part numbers (lowest prtnum
-- wins, deterministic across runs).
nearest_verified as (

    select concept_norm, nearest_prtnum, item_name
    from (
        select
            nr.concept_norm,
            nr.nearest_prtnum,
            itm.item_name,
            row_number() over (
                partition by nr.concept_norm, itm.item_name
                order by nr.nearest_prtnum
            )                                                          as _name_rn
        from (select distinct concept_norm, nearest_prtnum from nearest_raw) as nr
        inner join items as itm
            on itm.prtnum = nr.nearest_prtnum
    )
    where _name_rn = 1

),

-- Both array_agg()s in ONE aggregate so name [i] belongs to prtnum [i] — the same
-- single-pass argument as rec_agg, asserted by
-- tests/assert_social_nearest_items_aligned.sql.
nearest_agg as (

    select
        concept_norm,
        array_agg(nearest_prtnum)                                      as nearest_prtnums,
        array_agg(item_name)                                           as nearest_items
    from nearest_verified
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

        -- the group's display name when the resolver judged several concepts to be
        -- one thing, else this concept's own label
        coalesce(r.group_label, r.canonical_label, b.concept_norm)       as concept_label,
        b.trend_rank,
        b.rank_change,
        b.mention_count,
        b.subject_mentions,
        b.ingredient_mentions,
        b.unlabelled_mentions,
        b.has_subject_evidence,
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
    -- HOW the concept was mentioned, not just how often. subject = the post is about
    -- it; ingredient = it was named as a component of something else. They sum to
    -- mention_count together with unlabelled_mentions (mentions not yet re-labelled
    -- at enrichment prompt v4). See int_social_concept_trends for why the total is
    -- deliberately left alone.
    j.subject_mentions,
    j.ingredient_mentions,
    j.unlabelled_mentions,
    -- false means source_links are posts that merely NAMED the concept — there were
    -- no posts about it to show. Read the evidence accordingly.
    j.has_subject_evidence,
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
    -- CURRENT stock, not as-of this row's week — see the stock CTE.
    -- BOOLEAN, not the upstream 0/1 mask: this column is read by people, and "1" beside
    -- a product name is ambiguous (one unit? one SKU? in stock?). Written as `= 1`
    -- rather than a cast so the THREE states survive — true (shippable), false
    -- (recorded, not shippable), null (no stock record for this part number at all,
    -- which is not the same as knowing it is out). int_jdawms_stock_weekly keeps the
    -- integer mask, correctly: max()/min()/fraction over days only make sense on 0/1.
    st.in_stock = 1                                                    as current_in_stock,
    st.shippable_qty                                                   as current_shippable_qty,

    -- recommendations: only real SKUs (verified against the item master), shown
    -- with their authoritative names; dropped when the match was low-confidence
    ra.recommended_prtnums,
    ra.recommended_items,

    -- CARRIED SKUS: every SKU of this product we stock — the matched item plus our
    -- other brands, sizes and pack formats of it, matched item first. Only populated
    -- for a carried match, derived from the item master rather than the LLM, and a
    -- FLOOR rather than a census (see alt_matched).
    aa.carried_prtnums,
    aa.carried_items,
    aa.carried_sku_count,

    -- NEAREST: only populated when result_type = 'none' and the resolver still found
    -- real, active SKUs — either rejected by the verifier or suppressed by the
    -- confidence floor (see nearest_raw). NOT a recommendation: these are the items a
    -- human should look at before concluding we carry nothing. Null on every row that
    -- has a real match.
    na.nearest_prtnums,
    na.nearest_items,
    -- only meaningful when there's an actual match shown; null for none/unresolved
    -- (a confidence score on a "no match" is noise)
    case when j.result_type_adj in ('carried', 'substitute', 'basket')
         then j.match_confidence end                                    as match_confidence,

    -- what marketing should do (about TODAY's stock — see the stock CTE)
    case
        when j.result_type_adj = 'carried'    and coalesce(st.in_stock, 0) = 1 then 'promote_now'
        when j.result_type_adj = 'carried'    and coalesce(st.in_stock, 0) = 0 then 'restock'
        when j.result_type_adj = 'substitute'                                  then 'offer_substitute'
        when j.result_type_adj = 'basket'                                      then 'promote_ingredients'
        -- 'source_new' only when we really did come up empty. If the resolver named
        -- active SKUs and they were rejected or floored, that is a call for a human to
        -- look, not a sourcing instruction — see nearest_raw.
        when j.result_type_adj = 'none'
             and na.nearest_prtnums is not null                                then 'review_nearest'
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
left join nearest_agg as na
    on na.concept_norm = j.concept_norm
left join carried_sku_agg as aa
    on aa.concept_norm = j.concept_norm
