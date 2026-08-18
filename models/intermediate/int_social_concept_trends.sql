{{ config(tags=['social']) }}
{% set history_weeks = var('social_trend_history_weeks') %}
-- int_social_concept_trends — WEEKLY trending boards, one row per (week_start,
-- concept_class, concept_norm). DETERMINISTIC and LLM-free. Recomputed and
-- replaced every run.
--
-- GRAIN: the CALENDAR WEEK (Monday-anchored posted_week, straight off
-- fct_social_mentions). Each row aggregates only that week's mentions and is
-- ranked against only that week's other concepts, because the report runs weekly
-- and the whole point is to compare week against week: same-length periods, no
-- overlap, so "up 3 places" and "share up 2 points" mean exactly what they say.
-- History is bounded by social_trend_history_weeks; "now" is max(week_start).
--
-- The known cost, stated so nobody rediscovers it as a bug: a calendar boundary
-- splits a trend. A spike that runs Saturday to Tuesday lands half in each of two
-- weeks and ranks lower in both than it would in either. An earlier version used a
-- trailing 4-week window specifically to avoid that, at the price of overlapping
-- periods that can't be compared week to week — which is the trade this grain
-- deliberately takes the other side of. Read rank_change/mention_share_change with
-- that in mind for anything that straddles a Sunday.
--
-- THE NEWEST WEEK IS USUALLY INCOMPLETE. If the run happens mid-week, the latest
-- row covers only the days collected so far, so its volume is low for a reason
-- that has nothing to do with the trend. days_observed says how many days are
-- actually in it and is_partial_week flags it (also true for the first week ever
-- collected). Charts and week-over-week reads should either exclude partial weeks
-- or lean on mention_share, which is a share of that same short week and so stays
-- comparable.
--
-- TWO RANKING CLASSES (concept_class), ranked SEPARATELY — this is the point:
--   'dish' <- mentioned_dishes  (Som Tam, Pho, banh khot — what people talk about)
--   'item' <- mentioned_products — SELLABLE PRODUCTS: branded or packaged/processed
--             goods a grocery or restaurant could order as a line item ("Tiparos
--             fish sauce", "canned coconut milk", "tom yum paste"). NOT raw
--             commodities or produce (durian, matcha, pork stay in `ingredients`
--             and are never ranked), not dishes, not categories, not retailers.
-- trend_rank is row_number() partitioned by (week_start, concept_class), so a
-- flood of viral dishes can no longer crowd stockable items off the board. Both
-- lists are always visible.
--
-- WHY `mentioned_products` AND NOT `ingredients`: the item board only earns its
-- slot if what's on it could be a purchase order line. `ingredients` is defined at
-- extraction as "notable ingredients", so it is structurally commodity-level —
-- ranking it yields durian / matcha / pork, which name a food but not a thing to
-- buy, and no stoplist can fix that (a stoplist removes the MOST generic tokens
-- and leaves the slightly-less-generic ones). The product/commodity judgment needs
-- the post's text, so it is made at extraction time instead —
-- scripts/enrich_mentions.py prompt v2. `ingredients` is still carried through the
-- fact and still feeds the resolver's ingredient-BASKET side; it is simply not a
-- ranking stream. Brands are not ranked either: that array is dominated by channels
-- people buy through (7-Eleven, Grab, LINE MAN), influencers and restaurants —
-- unbounded, none stockable. The resolver still reads brand context from snippets.
--
-- EXPECT THE ITEM BOARD TO BE THINNER than the dish board, by a lot. People post
-- "I ate som tam", not "I bought Tiparos fish sauce 700ml", so product mentions are
-- genuinely rarer — and with social_trend_min_mentions applied per week, some weeks
-- will have only a handful of item rows. That is sparse signal, not a broken model.
-- seed_social_generic_terms still anti-joins here as a BACKSTOP for commodity tokens
-- that slip through the extraction; it should be doing much less work than it did
-- when this class was sourced from `ingredients`.
--
-- SCORING (author-diversity based; replaced pure mention-volume ranking, which
-- correlated ~0.86 with raw mention_count — one loud account could outrank a
-- genuine trend):
--   trend_score = distinct_authors_adj
--               * (1 + ln(1+engagement_norm)/eng_weight + ln(1+views_norm)/views_weight)
--               * (single_channel_dampener if channel_count < 2 else 1)
-- distinct_authors_adj: see the anonymised-profile note below.
-- engagement_norm / views_norm: each mention's engagement/views, divided by (a)
--   its OWN channel's median for that metric THAT WEEK — so a Twitter post and a
--   TikTok post are judged against their own platform's normal scale, not each
--   other's (TikTok's median non-zero engagement is 70-280x every other channel's;
--   a raw sum is effectively a TikTok-only ranking otherwise) — and (b) the number
--   of OTHER concepts OF THE SAME CLASS that same mention also names, so a post
--   listing 26 dishes doesn't give every single one full credit for that post's
--   popularity. Summed across a concept's mentions, then log-dampened ONCE at the
--   end (same shape as the legacy formula) so no single post can dominate.
-- trend_score_legacy: the original mention-count-led formula, kept (not deleted)
--   so rankings can be compared over the next few weeks.
--
-- WHAT ONE CALENDAR WEEK IS TOO THIN FOR, and what is done about it:
--   * channel medians are per (week, channel), because channel scale is not
--     stationary — TikTok's median engagement in collection week 5 is not its
--     week-26 median, and one global median would make early weeks' ratios small
--     and late weeks' large, manufacturing a rise inside the score itself. But a
--     single week can leave a channel with a handful of rows, and a median over 2
--     rows is not a baseline, it's one of the two rows: below
--     social_trend_v2_min_channel_baseline_mentions the channel's ALL-HISTORY
--     median is used instead. That fallback matters more at this grain than it
--     would over a multi-week window — if a channel is thin most weeks, raise the
--     threshold rather than trusting a 3-row median.
--   * author_quality is judged on ONE week of mentions, so most concepts land on
--     'unverifiable' (fewer than social_trend_v2_min_named_mentions named mentions
--     in seven days) and the 'repeat_poster' exclusion fires less often than it did
--     over a longer window. Unverifiable concepts stay IN the ranking with the flag
--     visible, so nothing is silently dropped — but the anti-spam guard is weaker
--     per week by construction. Lower social_trend_v2_min_named_mentions if it
--     needs to bite weekly; named_mentions/named_authors are exposed so the call
--     can be made on real numbers.
--
-- WEEK-OVER-WEEK MEASURES (mention_share is the one to trust):
--   mention_share = this concept's (concept, mention) pairs / ALL pairs that week
--     in that class. Shares sum to ~1, so if the whole corpus doubles every share
--     is unchanged — which is what makes it robust to collection volume moving
--     (the artifact that made the old half-window is_rising read "rising" for ~85%
--     of concepts) and to a short partial week.
--   rank_change = prev_trend_rank - trend_rank, so POSITIVE = moved UP the board.
--   is_rising = mention_share went UP versus LAST WEEK.
--     REDEFINED at this grain: it used to compare the recent half of a 4-week
--     window against the older half, which was both noisy and volume-driven. A
--     half-of-one-calendar-week split (Thu-Sun vs Mon-Wed) would be worse, and a
--     real previous week is now available, so it is a true week-over-week rise.
--   ALL FOUR COMPARISONS ARE STRICT: populated only when the concept's previous row
--     is exactly the previous calendar week. lag() walks a concept's OBSERVED weeks,
--     and a week under the noise floor produces no row — so ungated, a concept that
--     charted in W29, went quiet in W30 and returned in W31 would report "+6 places"
--     against W29, a number indistinguishable from a real one-week move. NULL
--     therefore means "no like-for-like comparison exists", never "flat"; do not
--     coalesce it to 0. prev_week_start still carries the older week, so a
--     longer-range comparison is available on request — it just isn't served up as
--     if it were weekly.
--
-- ANONYMISED PROFILES: Instagram returns "Instagram User" for ~97% of Instagram
-- rows — confirmed with Mentionlytics as an Instagram API limitation (their
-- anonymisation, not ours), not evidence those rows share one real author.
-- distinct_authors_adj treats each such mention as its own unknown author
-- (assume good faith — we don't know who posted it, in either direction) —
-- but that alone would make ANY Instagram-heavy concept look automatically
-- author-diverse and pass a naive repeat-ratio check even if one real account
-- is spamming it, which is exactly the failure mode this metric exists to
-- catch. So the repeat-ratio exclusion runs on named_mentions/named_authors —
-- real, non-anonymised authors only — never on distinct_authors_adj:
--   author_quality = 'verified'       named_mentions >= min AND ratio <= max
--                   | 'repeat_poster' named_mentions >= min AND ratio >  max  (EXCLUDED from ranking)
--                   | 'unverifiable'  named_mentions <  min (too little named signal to judge either way —
--                                     stays IN the ranking with the flag visible; silently dropping every
--                                     Instagram-only concept would be worse than reporting we can't verify it)
--
-- is_single_channel is a DAMPENER, not an exclusion — measured at ~5% of the
-- actual top-20 (vs ~38% of the full long tail), so a single-platform trend
-- (very common — TikTok-only food virality is a real, legitimate pattern) isn't
-- silently removed, just ranked a little more conservatively.
--
-- source_links carries the top mention URLs behind the concept THAT WEEK (by
-- reach then engagement).
--
-- Materialized as a table (the intermediate-layer default) and deliberately NOT
-- incremental, even though calendar weeks look append-only: the newest week is
-- still partial and its rows change on the next run, late-arriving mentions
-- restate a past week, the all-history channel medians move every week, and the
-- history bound slides. Full recompute is cheap at this size and always correct.
--
-- It is also the GATE scripts/resolve_trending_concepts.py reads to pick which
-- concepts to resolve to SKUs (only rows with a non-null trend_rank —
-- repeat_poster rows have trend_rank = null, so a plain `where trend_rank <= N`
-- already excludes them with no script change needed).

with mentions as (

    select
        mention_id,
        profile,
        channel,
        cast(posted_date as date)                                       as posted_date,
        -- Monday-anchored calendar week, already materialised by
        -- fct_social_mentions, so it is not recomputed here (one definition of
        -- "which week is this", not two that can drift). THIS is the grain.
        cast(posted_week as date)                                       as posted_week,
        -- engagement = ACTIVE reactions; use the component columns (populated more
        -- often than Mentionlytics' aggregate total_engagement, which is ~45% null)
        coalesce(likes, 0) + coalesce(comments, 0) + coalesce(shares, 0) as engagement,
        coalesce(views, 0)                                              as views,
        follower_count,
        link,
        sentiment_normalized,
        mentioned_dishes,
        mentioned_products
    from {{ ref('fct_social_mentions') }}

),

bounds as (

    select
        max(posted_date) as data_max_date,
        min(posted_date) as data_min_date,
        max(posted_week) as latest_week
    from mentions

),

-- Retained history only. No windowing beyond this: one mention belongs to exactly
-- ONE week, which is what makes the week-to-week comparison downstream exact.
scoped as (

    select
        m.*,
        m.posted_week                                                   as week_start,
        cast({{ dbt.dateadd('day', 6, 'm.posted_week') }} as date)      as week_end,
        -- how much of the week we actually hold data for. Short at both ends of the
        -- series: the first week collected and the week currently in progress.
        {{ dbt.datediff(
             'greatest(m.posted_week, b.data_min_date)',
             'least(cast(' ~ dbt.dateadd('day', 6, 'm.posted_week') ~ ' as date), b.data_max_date)',
             'day') }} + 1                                              as days_observed
    from mentions as m
    cross join bounds as b
    where m.posted_week >= cast({{ dbt.dateadd('day', -7 * (history_weeks - 1), 'b.latest_week') }} as date)

),

-- per-(week, channel) baseline over ALL that week's mentions (not just
-- concept-bearing ones) so a channel's typical scale isn't itself biased by which
-- posts happen to name something. median() is verified identical on DuckDB and
-- Databricks (unlike the regex escaping fold_concept/strip_parenthetical_gloss
-- had to work around).
channel_baseline_week as (

    select
        week_start,
        channel,
        median(engagement)                                              as channel_median_engagement,
        median(views)                                                   as channel_median_views,
        count(*)                                                        as n_mentions
    from scoped
    group by 1, 2

),

-- all-history fallback for a channel too thin in a given week to have a
-- meaningful median. Reads `mentions` rather than `scoped` on purpose: the widest
-- possible base for a stand-in, including weeks aged out of the retained history.
channel_baseline_global as (

    select
        channel,
        median(engagement)                                              as channel_median_engagement,
        median(views)                                                   as channel_median_views
    from mentions
    group by 1

),

channel_baseline as (

    select
        w.week_start,
        w.channel,
        case when w.n_mentions >= {{ var('social_trend_v2_min_channel_baseline_mentions') }}
             then w.channel_median_engagement
             else g.channel_median_engagement end                       as channel_median_engagement,
        case when w.n_mentions >= {{ var('social_trend_v2_min_channel_baseline_mentions') }}
             then w.channel_median_views
             else g.channel_median_views end                            as channel_median_views
    from channel_baseline_week as w
    left join channel_baseline_global as g
        on g.channel = w.channel

),

-- ratio-to-channel-median: makes a TikTok post and a Twitter post comparable on
-- their own platform's terms, and — unlike a 0-1 percentile rank — keeps a post
-- that's 100x its channel's median looking like 100x, not just "near the top".
-- A channel with zero variance (median = 0, e.g. Web) contributes 0: no signal
-- either way, not a penalty for a structural channel characteristic.
--
-- The baseline join MUST carry week_start as well as channel. channel_baseline is
-- unique on (week_start, channel); joining on channel alone silently fans this
-- LEFT JOIN out once per retained week. It is the highest-risk join here.
mentions_normalized as (

    select
        m.mention_id, m.profile, m.channel, m.posted_date, m.follower_count, m.link,
        m.sentiment_normalized, m.mentioned_dishes, m.mentioned_products,
        m.week_start, m.week_end, m.days_observed,
        m.engagement, m.views,
        case when cb.channel_median_engagement > 0
             then m.engagement * 1.0 / cb.channel_median_engagement else 0 end as engagement_ratio,
        case when cb.channel_median_views > 0
             then m.views * 1.0 / cb.channel_median_views else 0 end           as views_ratio
    from scoped as m
    left join channel_baseline as cb
        on cb.channel    = m.channel
       and cb.week_start = m.week_start

),

-- The two class streams. macros/unnest.sql allows exactly ONE generator per
-- SELECT on both engines, so each array gets its own select and they are UNION
-- ALLed. `union all`, never `union`: a mention naming the same string as both a
-- dish and an ingredient must keep both rows — the classes are separate rank
-- spaces. Both branches list the same columns in the same order because UNION ALL
-- matches by position, hence no `select *` inside them.
dish_concepts_raw as (

    select
        mention_id, profile, channel, posted_date, engagement, views,
        engagement_ratio, views_ratio, follower_count, link, sentiment_normalized,
        week_start, week_end, days_observed,
        'dish'                                                          as concept_class,
        {{ unnest('mentioned_dishes') }}                                as concept
    from mentions_normalized

),

item_concepts_raw as (

    select
        mention_id, profile, channel, posted_date, engagement, views,
        engagement_ratio, views_ratio, follower_count, link, sentiment_normalized,
        week_start, week_end, days_observed,
        'item'                                                          as concept_class,
        {{ unnest('mentioned_products') }}                              as concept
    from mentions_normalized

),

concepts_raw as (

    select * from dish_concepts_raw
    union all
    select * from item_concepts_raw

),

-- strip a trailing LLM-appended gloss ("ขนมโตเกียว (tokyo pastry/snack)" ->
-- "ขนมโตเกียว") BEFORE folding. Kept as its own step so the empty-string edge
-- case (a concept that's entirely parenthetical) can fall back to the
-- original text instead of silently disappearing.
concepts_degloss as (

    select
        mention_id, profile, channel, posted_date, engagement, views,
        engagement_ratio, views_ratio, follower_count, link, sentiment_normalized,
        week_start, week_end, days_observed,
        concept_class,
        concept,
        {{ strip_parenthetical_gloss('concept') }}                      as concept_deglossed
    from concepts_raw
    where nullif(trim(concept), '') is not null

),

concepts as (

    select
        mention_id, profile, channel, posted_date, engagement, views,
        engagement_ratio, views_ratio, follower_count, link, sentiment_normalized,
        week_start, week_end, days_observed,
        concept_class,
        -- fold Vietnamese diacritic/case/spacing variants to one key so the same
        -- thing (bánh khọt / banh khot) ranks once, not several times
        {{ fold_concept(
            "case when nullif(concept_deglossed, '') is not null then concept_deglossed else concept end"
        ) }}                                                            as concept_norm
    from concepts_degloss

),

-- generic-commodity stoplist, folded with the SAME macro the concepts are folded
-- with (one folding implementation, both sides). Folded once here rather than in
-- the join predicate so neither engine evaluates a regex per probe row.
generic_terms as (

    select
        {{ fold_concept('term') }}                                      as term_norm,
        applies_to
    from {{ ref('seed_social_generic_terms') }}
    where coalesce(is_active, true)

),

-- Anti-join UPSTREAM of ranking, not a filter on the finished board. Three
-- reasons, the first fatal: (1) row_number() counts every row in its ordering, so
-- removing rows afterwards leaves GAPS in the surviving ranks — the exact thing
-- assert_social_concept_trends_rank_is_dense forbids; (2) mention_share's
-- denominator must exclude generic terms too, or every real item's share is
-- diluted by a constant flood of salt/water/oil; (3) the shared-post divisor must
-- not be inflated by them — a post naming 3 real ingredients plus salt, water and
-- oil should divide by 3, not 6. The cost is that suppressed terms are invisible
-- here; dq_social_generic_term_hits counts them separately so the stoplist stays
-- auditable.
concepts_kept as (

    select c.*
    from concepts as c
    left join generic_terms as g
        on g.term_norm = c.concept_norm
       and (g.applies_to = 'all' or g.applies_to = c.concept_class)
    where g.term_norm is null

),

-- one row per (week, class, concept, mention) — a mention naming a thing twice
-- counts once. concept_class must be in the distinct list: a string that is both a
-- dish and an ingredient in one post would otherwise collapse and one of the two
-- classes would lose a mention. week_start is functionally determined by the
-- mention (one mention, one calendar week), and is listed because it is part of
-- the grain, not to make the DISTINCT correct.
concept_mentions as (

    select distinct
        week_start, week_end, days_observed, concept_class,
        concept_norm, mention_id, profile, channel, posted_date,
        engagement, views, engagement_ratio, views_ratio,
        follower_count, link, sentiment_normalized,
        -- anonymised placeholder, confirmed with Mentionlytics as an Instagram
        -- API limitation (~97% of Instagram rows) — extend this list if another
        -- platform's anonymisation shows up the same way.
        (profile = 'Instagram User')                                    as is_anon,
        concat(channel, ':', lower(trim(profile)))                      as author_key
    from concepts_kept

),

-- how many OTHER concepts OF THE SAME CLASS does this same mention also name? —
-- the shared-post divisor. WITHIN class, because the classes are independent rank
-- spaces: cross-normalising would let a post that happened to name a lot of dishes
-- deflate an item's score, which is the coupling the separate rank spaces exist to
-- remove.
mention_concept_counts as (

    select
        mention_id,
        concept_class,
        count(distinct concept_norm)                                    as n_concepts
    from concepts_kept
    group by 1, 2

),

concept_mentions_shared as (

    select
        cm.*,
        cm.engagement_ratio / mcc.n_concepts                            as engagement_share,
        cm.views_ratio      / mcc.n_concepts                            as views_share
    from concept_mentions as cm
    inner join mention_concept_counts as mcc
        on mcc.mention_id    = cm.mention_id
       and mcc.concept_class = cm.concept_class

),

agg as (

    select
        week_start,
        concept_class,
        concept_norm,
        -- functionally dependent on week_start, not independent facts — max()
        -- carries them through the group by rather than widening the grain
        max(week_end)                                                  as week_end,
        max(days_observed)                                             as days_observed,
        count(*)                                                       as mention_count,
        sum(engagement)                                                as total_engagement,
        sum(views)                                                     as total_views,
        sum(engagement_share)                                          as engagement_norm,
        sum(views_share)                                                as views_norm,
        -- anonymised mentions each count as their own unknown author
        count(distinct case when is_anon then concat('anon_', mention_id) else author_key end)
                                                                        as distinct_authors_adj,
        -- named-author companion: real, non-anonymised authors only
        count(distinct case when not is_anon then author_key end)      as named_authors,
        sum(case when not is_anon then 1 else 0 end)                   as named_mentions,
        count(distinct channel)                                        as channel_count,
        sum(case when sentiment_normalized = 'positive' then 1
                 when sentiment_normalized = 'negative' then -1
                 else 0 end)                                           as net_sentiment
    from concept_mentions_shared
    group by 1, 2, 3

),

-- mention_share's denominator: every (concept, mention) pair that week in that
-- class, AFTER the stoplist and BEFORE the noise floor. Shares then sum to ~1
-- within a class, which is what makes the metric comparable across weeks of
-- different size — including a partial one. Two rejected alternatives: a distinct
-- mention count (shares stop summing to 1, so a week where posts got wordier makes
-- everything look risen — a volume artifact in a new costume) and reading `final`
-- (a denominator that moves with social_trend_min_mentions is not a share). Must
-- group by week_start as well as class, or every share comes out one-week-in-N too
-- small and still looks plausible —
-- assert_social_concept_trends_mention_share_sums is the guard.
week_totals as (

    select
        week_start,
        concept_class,
        count(*)                                                       as week_mentions
    from concept_mentions
    group by 1, 2

),

final as (

    select
        *,
        case
            when named_mentions >= {{ var('social_trend_v2_min_named_mentions') }}
                 and named_mentions * 1.0 / named_authors <= {{ var('social_trend_v2_max_mentions_per_named_author') }}
                then 'verified'
            when named_mentions >= {{ var('social_trend_v2_min_named_mentions') }}
                then 'repeat_poster'
            else 'unverifiable'
        end                                                            as author_quality,
        channel_count < 2                                               as is_single_channel
    from agg
    -- per (week, class): a concept below the floor in one week simply has no row
    -- for that week, which is why the mart carries a concept's whole trajectory
    -- rather than filtering by rank. The floor bites harder at a 7-day grain than
    -- it did over a multi-week window — expect more gaps in a trajectory.
    where mention_count >= {{ var('social_trend_min_mentions') }}

),

scored as (

    select
        f.*,
        f.mention_count * 1.0 / wt.week_mentions                       as mention_share,
        -- legacy score, kept (not deleted) so rankings can be compared over the next few weeks
        f.mention_count
            * (1 + ln(1 + coalesce(f.total_engagement, 0)) / {{ var('social_trend_engagement_weight') }}
                 + ln(1 + coalesce(f.total_views, 0))      / {{ var('social_trend_views_weight') }})  as trend_score_legacy,
        -- current score (author-diversity based)
        f.distinct_authors_adj
            * (1 + ln(1 + f.engagement_norm) / {{ var('social_trend_v2_engagement_weight') }}
                 + ln(1 + f.views_norm)      / {{ var('social_trend_v2_views_weight') }})
            * (case when f.is_single_channel
                    then {{ var('social_trend_v2_single_channel_dampener') }} else 1 end)             as trend_score
    from final as f
    inner join week_totals as wt
        on wt.week_start    = f.week_start
       and wt.concept_class = f.concept_class

),

-- top-N source links per (week, class, concept): highest reach first, then engagement
links_ranked as (

    select
        week_start,
        concept_class,
        concept_norm,
        link,
        row_number() over (
            partition by week_start, concept_class, concept_norm
            order by coalesce(follower_count, 0) desc,
                     coalesce(engagement, 0) desc,
                     mention_id
        )                                                              as _rn
    from concept_mentions_shared
    where link is not null

),

links_agg as (

    -- no `order by` inside array_agg: DuckDB accepts it, Databricks' collect_list
    -- does not. The _rn filter is what makes this a top-N SET; order isn't promised.
    select week_start, concept_class, concept_norm, array_agg(link) as source_links
    from links_ranked
    where _rn <= {{ var('social_trend_link_count') }}
    group by 1, 2, 3

),

-- rank over the FILTERED subset only, not the whole table with the rank blanked
-- out afterward — row_number() still counts every row in its ordering even when
-- you null the result out in a CASE, which would leave gaps in the visible ranks
-- (the exact thing the "dense ranking, no gaps" test checks for). Filtering
-- before ranking, then joining the rank back, is the only way to keep it dense.
--
-- partition by (week_start, concept_class): the rank is a position on ONE week's
-- board, in ONE class. Both keys matter — the week because that is the comparison
-- unit, the class because that is the anti-masking mechanism.
ranked as (

    select
        week_start,
        concept_class,
        concept_norm,
        row_number() over (
            partition by week_start, concept_class
            order by trend_score desc, mention_count desc, concept_norm
        )                                                              as trend_rank
    from scored
    where author_quality != 'repeat_poster'

),

with_rank as (

    select
        s.week_start,
        s.week_end,
        -- the ISO week NUMBER (1-53) and a sortable label ("2026-W34"), so a report
        -- can say "week 34" instead of a date. The ISO YEAR is taken from the week's
        -- THURSDAY, not from week_start: a Monday can sit in the previous calendar
        -- year while belonging to week 1 of the next (Mon 2025-12-29 is 2026-W01), so
        -- year(week_start) would label it "2025-W01". Verified against DuckDB's
        -- isoyear() on every boundary case; the Thursday rule is used because
        -- isoyear() is DuckDB-only while year() + dateadd are portable, and
        -- weekofyear() is ISO under the same name on both engines.
        weekofyear(s.week_start)                                       as week_of_year,
        cast(year(cast({{ dbt.dateadd('day', 3, 's.week_start') }} as date)) as {{ dbt.type_string() }})
            || '-W'
            || lpad(cast(weekofyear(s.week_start) as {{ dbt.type_string() }}), 2, '0')
                                                                        as year_week,
        s.concept_class,
        s.concept_norm,
        s.days_observed,
        s.days_observed < 7                                            as is_partial_week,
        s.mention_count,
        s.mention_share,
        s.total_engagement,
        s.total_views,
        s.net_sentiment,
        s.distinct_authors_adj,
        s.named_authors,
        s.named_mentions,
        s.channel_count,
        s.author_quality,
        s.is_single_channel,
        s.trend_score_legacy,
        s.trend_score,
        la.source_links,
        -- excluded (repeat_poster) concepts get NO rank — still inspectable in the
        -- table, but resolve_trending_concepts.py's `where trend_rank <= N` and
        -- the mart's same filter both exclude them for free (NULL <= N is never
        -- true in SQL).
        r.trend_rank
    from scored as s
    left join links_agg as la
        on la.week_start    = s.week_start
       and la.concept_class = s.concept_class
       and la.concept_norm  = s.concept_norm
    left join ranked as r
        on r.week_start    = s.week_start
       and r.concept_class = s.concept_class
       and r.concept_norm  = s.concept_norm

),

-- week-over-week comparisons over a concept's OBSERVED weeks. lag() ignores the
-- frame, so no `rows between` is needed; prev_week_start is carried because
-- "previous row" is not always "previous calendar week" (a week below the noise
-- floor has no row) and prev_trend_rank would otherwise read as last week's.
rise_lagged as (

    select
        w.*,
        lag(w.week_start) over (
            partition by w.concept_class, w.concept_norm order by w.week_start)    as prev_week_start,
        lag(w.trend_rank) over (
            partition by w.concept_class, w.concept_norm order by w.week_start)    as prev_trend_rank,
        lag(w.mention_count) over (
            partition by w.concept_class, w.concept_norm order by w.week_start)    as prev_mention_count,
        lag(w.mention_share) over (
            partition by w.concept_class, w.concept_norm order by w.week_start)    as prev_mention_share
    from with_rank as w

)

-- STRICT WEEK-OVER-WEEK. Every comparison below is populated ONLY when the
-- concept's previous row is exactly the previous calendar week, so a number here
-- always means "versus last week" and nothing else.
--
-- Why it has to be gated: lag() walks a concept's OWN observed weeks, and a week
-- where it fell under social_trend_min_mentions produces no row at all. Ungated, a
-- concept that charted in W29, went quiet in W30 and came back in W31 would report
-- "+6 places" against W29 — indistinguishable, in the number itself, from a real
-- one-week move. At a calendar-week grain whose entire purpose is comparing equal
-- adjacent periods, that is the one thing these columns must not do.
--
-- NULL therefore means "no like-for-like comparison exists" (first appearance, a
-- skipped week, or a week either side was excluded as repeat_poster) — never
-- "flat". Do not coalesce it to 0. prev_week_start still carries the older week, so
-- a longer-range comparison is available to anyone who explicitly wants one; it
-- just isn't served up as if it were weekly.
-- one definition of "the previous row really is last week", shared by all four
-- measures. Kept as a Jinja string rather than a column so the final select can
-- stay `l.*` — dropping a helper column afterwards would need EXCLUDE on DuckDB
-- and EXCEPT on Databricks, which is exactly the kind of dialect split this
-- project keeps out of the models.
{% set is_consecutive %}
    l.prev_week_start = cast({{ dbt.dateadd('day', -7, 'l.week_start') }} as date)
{% endset %}

select
    l.*,
    -- POSITIVE = moved UP the board (8 -> 3 is +5).
    case when {{ is_consecutive }}
         then l.prev_trend_rank - l.trend_rank end                      as rank_change,
    case when {{ is_consecutive }} and l.prev_mention_count > 0
         then (l.mention_count - l.prev_mention_count) * 1.0 / l.prev_mention_count
    end                                                                 as mention_count_wow_pct,
    case when {{ is_consecutive }}
         then l.mention_share - l.prev_mention_share end                as mention_share_change,
    -- share went UP on the immediately preceding week
    case when {{ is_consecutive }}
         then l.mention_share > l.prev_mention_share end                as is_rising
from rise_lagged as l
