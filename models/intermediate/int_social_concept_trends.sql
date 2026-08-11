{{ config(tags=['social']) }}
{% set window_days = 7 * var('social_trend_window_weeks') %}
{% set half_days = (window_days / 2) | int %}
-- int_social_concept_trends — "currently trending" snapshot, one row per concept.
-- DETERMINISTIC and LLM-free. NOT per-week: it aggregates ALL mentions in a
-- TRAILING WINDOW of social_trend_window_weeks ending at the latest data
-- (window_end = max posted_date), so a dish talked about for weeks keeps ranking
-- until its mentions age out of the window — that is what "currently trending"
-- means. Recomputed and replaced every run.
--
-- CURRENT SCORING (author-diversity based; replaced pure mention-volume
-- ranking, which correlated ~0.86 with raw mention_count — one loud account
-- could outrank a genuine trend):
--   trend_score = distinct_authors_adj
--               * (1 + ln(1+engagement_norm)/eng_weight + ln(1+views_norm)/views_weight)
--               * (single_channel_dampener if channel_count < 2 else 1)
-- distinct_authors_adj: see the anonymised-profile note below.
-- engagement_norm / views_norm: each mention's engagement/views, divided by (a)
--   its OWN channel's median for that metric — so a Twitter post and a TikTok
--   post are judged against their own platform's normal scale, not each other's
--   (TikTok's median non-zero engagement is 70-280x every other channel's; a raw
--   sum is effectively a TikTok-only ranking otherwise) — and (b) the number of
--   OTHER concepts that same mention also names, so a post listing 26 dishes
--   doesn't give every single one full credit for that post's popularity. Summed
--   across a concept's mentions, then log-dampened ONCE at the end (same shape as
--   the legacy formula) so no single post can dominate. A channel with zero
--   engagement variance (Web: 100% zero) can't be divided by its own median (0),
--   so it contributes 0 rather than erroring — a neutral no-signal-either-way
--   default, not a penalty.
-- trend_score_legacy: the original mention-count-led formula, kept (not deleted)
--   so rankings can be compared over the next few weeks.
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
-- is_rising is a SECONDARY flag (recent half of the window vs the older half),
-- surfaced for context — it does NOT drive the sort. (Known to be dominated by
-- the data collection ramp-up rather than real trend dynamics — out of scope,
-- reported separately, not fixed here.)
--
-- The trending UNIT is mentioned_dishes only (the AI's specific-product signal);
-- ingredients (too generic) and brands (channels/influencers/restaurants) are not
-- ranked. source_links carries the top mention URLs behind the concept (by reach
-- then engagement).
--
-- Materialized as a table: it is the GATE scripts/resolve_trending_concepts.py
-- reads to pick which top-N concepts to resolve to SKUs (only rows with a
-- non-null trend_rank — repeat_poster rows have trend_rank = null, so a plain
-- `where trend_rank <= N` already excludes them with no script change needed).

with mentions as (

    select
        mention_id,
        profile,
        channel,
        cast(posted_date as date)                                       as posted_date,
        -- engagement = ACTIVE reactions; use the component columns (populated more
        -- often than Mentionlytics' aggregate total_engagement, which is ~45% null)
        coalesce(likes, 0) + coalesce(comments, 0) + coalesce(shares, 0) as engagement,
        coalesce(views, 0)                                              as views,
        follower_count,
        link,
        sentiment_normalized,
        mentioned_dishes
    from {{ ref('fct_social_mentions') }}

),

bounds as (

    select max(posted_date) as window_end from mentions

),

scoped as (

    select
        m.*,
        b.window_end,
        cast({{ dbt.dateadd('day', -1 * (window_days - 1), 'b.window_end') }} as date) as window_start,
        cast({{ dbt.dateadd('day', -1 * half_days, 'b.window_end') }} as date)         as recent_cutoff
    from mentions as m
    cross join bounds as b

),

in_window as (

    select * from scoped where posted_date >= window_start

),

-- per-channel baseline, over ALL in-window mentions (not just dish-bearing ones)
-- so a channel's typical scale isn't itself biased by which posts happen to name
-- a dish. median() is verified identical on DuckDB and Databricks (unlike the
-- regex escaping fold_concept/strip_parenthetical_gloss had to work around).
channel_baseline as (

    select
        channel,
        median(engagement) as channel_median_engagement,
        median(views)      as channel_median_views
    from in_window
    group by channel

),

-- ratio-to-channel-median: makes a TikTok post and a Twitter post comparable on
-- their own platform's terms, and — unlike a 0-1 percentile rank — keeps a post
-- that's 100x its channel's median looking like 100x, not just "near the top".
-- A channel with zero variance (median = 0, e.g. Web) contributes 0: no signal
-- either way, not a penalty for a structural channel characteristic.
mentions_normalized as (

    select
        m.mention_id, m.profile, m.channel, m.posted_date, m.follower_count, m.link,
        m.sentiment_normalized, m.mentioned_dishes, m.window_start, m.window_end, m.recent_cutoff,
        m.engagement, m.views,
        case when cb.channel_median_engagement > 0
             then m.engagement * 1.0 / cb.channel_median_engagement else 0 end as engagement_ratio,
        case when cb.channel_median_views > 0
             then m.views * 1.0 / cb.channel_median_views else 0 end           as views_ratio
    from in_window as m
    left join channel_baseline as cb
        on cb.channel = m.channel

),

-- explode the dish stream (the specific-product signal). ONE unnest per select.
concepts_raw as (

    select
        mention_id, profile, channel, posted_date, engagement, views, engagement_ratio, views_ratio,
        follower_count, link, sentiment_normalized, window_start, window_end, recent_cutoff,
        {{ unnest('mentioned_dishes') }}                                as concept
    from mentions_normalized

),

-- strip a trailing LLM-appended gloss ("ขนมโตเกียว (tokyo pastry/snack)" ->
-- "ขนมโตเกียว") BEFORE folding. Kept as its own step so the empty-string edge
-- case (a concept that's entirely parenthetical) can fall back to the
-- original text instead of silently disappearing.
concepts_degloss as (

    select
        mention_id, profile, channel, posted_date, engagement, views, engagement_ratio, views_ratio,
        follower_count, link, sentiment_normalized, window_start, window_end, recent_cutoff,
        concept,
        {{ strip_parenthetical_gloss('concept') }}                      as concept_deglossed
    from concepts_raw
    where nullif(trim(concept), '') is not null

),

concepts as (

    select
        mention_id, profile, channel, posted_date, engagement, views, engagement_ratio, views_ratio,
        follower_count, link, sentiment_normalized, window_start, window_end, recent_cutoff,
        -- fold Vietnamese diacritic/case/spacing variants to one key so the same
        -- dish (bánh khọt / banh khot) ranks once, not several times
        {{ fold_concept(
            "case when nullif(concept_deglossed, '') is not null then concept_deglossed else concept end"
        ) }}                                                            as concept_norm
    from concepts_degloss

),

-- one row per (concept, mention) — a mention naming a dish twice counts once
concept_mentions as (

    select distinct
        concept_norm, mention_id, profile, channel, posted_date,
        engagement, views, engagement_ratio, views_ratio,
        follower_count, link, sentiment_normalized,
        window_start, window_end, recent_cutoff,
        -- anonymised placeholder, confirmed with Mentionlytics as an Instagram
        -- API limitation (~97% of Instagram rows) — extend this list if another
        -- platform's anonymisation shows up the same way.
        (profile = 'Instagram User')                                    as is_anon,
        concat(channel, ':', lower(trim(profile)))                      as author_key
    from concepts

),

-- how many OTHER concepts does this same mention also name? — the Fix-4 divisor,
-- scoped to the mentioned_dishes dimension only (the only thing this model ranks).
mention_concept_counts as (

    select mention_id, count(distinct concept_norm) as n_concepts
    from concept_mentions
    group by mention_id

),

concept_mentions_shared as (

    select
        cm.*,
        cm.engagement_ratio / mcc.n_concepts                            as engagement_share,
        cm.views_ratio      / mcc.n_concepts                            as views_share
    from concept_mentions as cm
    inner join mention_concept_counts as mcc
        on mcc.mention_id = cm.mention_id

),

agg as (

    select
        concept_norm,
        max(window_start)                                              as window_start,
        max(window_end)                                                as window_end,
        count(*)                                                       as mention_count,
        sum(engagement)                                                as total_engagement,
        sum(views)                                                     as total_views,
        sum(engagement_share)                                          as engagement_norm,
        sum(views_share)                                                as views_norm,
        -- Fix 1: anonymised mentions each count as their own unknown author
        count(distinct case when is_anon then concat('anon_', mention_id) else author_key end)
                                                                        as distinct_authors_adj,
        -- named-author companion (Required Change 1): real, non-anonymised authors only
        count(distinct case when not is_anon then author_key end)      as named_authors,
        sum(case when not is_anon then 1 else 0 end)                   as named_mentions,
        count(distinct channel)                                        as channel_count,
        sum(case when sentiment_normalized = 'positive' then 1
                 when sentiment_normalized = 'negative' then -1
                 else 0 end)                                           as net_sentiment,
        sum(case when posted_date >  recent_cutoff then 1 else 0 end)  as recent_mentions,
        sum(case when posted_date <= recent_cutoff then 1 else 0 end)  as prior_mentions
    from concept_mentions_shared
    group by 1

),

-- top-N source links per concept: highest reach first, then engagement
links_ranked as (

    select
        concept_norm,
        link,
        row_number() over (
            partition by concept_norm
            order by coalesce(follower_count, 0) desc,
                     coalesce(engagement, 0) desc,
                     mention_id
        )                                                              as _rn
    from concept_mentions_shared
    where link is not null

),

links_agg as (

    select concept_norm, array_agg(link) as source_links
    from links_ranked
    where _rn <= {{ var('social_trend_link_count') }}
    group by 1

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
    where mention_count >= {{ var('social_trend_min_mentions') }}

),

scored as (

    select
        f.*,
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

),

-- rank over the FILTERED subset only, not the whole table with the rank blanked
-- out afterward — row_number() still counts every row in its ordering even when
-- you null the result out in a CASE, which would leave gaps in the visible ranks
-- (the exact thing the "dense ranking, no gaps" test checks for). Filtering
-- before ranking, then joining the rank back, is the only way to keep it dense.
ranked as (

    select
        concept_norm,
        row_number() over (
            order by trend_score desc, mention_count desc, concept_norm
        )                                                              as trend_rank
    from scored
    where author_quality != 'repeat_poster'

)

select
    s.concept_norm,
    'dish'                                                             as concept_source,
    s.window_start,
    s.window_end,
    s.mention_count,
    s.total_engagement,
    s.total_views,
    s.net_sentiment,
    s.recent_mentions,
    s.prior_mentions,
    s.recent_mentions > s.prior_mentions                              as is_rising,
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
    -- table above, but resolve_trending_concepts.py's `where trend_rank <= N`
    -- and the mart's same filter both exclude them for free, no script change
    -- needed (NULL <= N is never true in SQL).
    r.trend_rank
from scored as s
left join links_agg as la
    on la.concept_norm = s.concept_norm
left join ranked as r
    on r.concept_norm = s.concept_norm
