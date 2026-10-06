{{ config(tags=['social']) }}
{% set lam = 0.5 ** (1.0 / var('social_trend_fade_half_life_weeks')) %}
{% set top_n = var('social_trend_top_n') %}
-- int_social_trend_board — the trending board with STAYING POWER. One row per
-- (week, class, product) for every product that was ever on the board or on the
-- Rising list, for every week from its first appearance on — INCLUDING weeks it had no
-- posts, which is what lets a product fade out instead of vanishing.
--
-- WHY. Ranked one calendar week at a time (int_social_concept_trends), a product that
-- went viral was gone the week its posting slowed: measured 2026-10-05, 63% of the item
-- board changed every week and an item stayed 1.6 weeks on average. Sponge cake —
-- 32 posts the week of Aug 24, then 15, 3, 0, 3 — was on the board for exactly one week.
--
-- HOW, in four parts:
--
--  1. SIGNAL = the product's SHARE of its board's trend_score that week, not the score
--     itself. Shares make weeks of very different size comparable — the feed changed
--     size three times in 2026 for reasons that are not trends: the keyword cut of Aug
--     16-17 (Thai tracker 10 -> 5 keywords), the monthly quota running out ~Sep 8-21,
--     and the enrichment v3 -> v4 change (~15-20% more products per post).
--
--  2. LOW-COVERAGE WEEKS. A week whose post count is below
--     social_trend_low_coverage_ratio x the retained weeks' median is a hole in the
--     data, not a quiet week (Sep 14: 153 food posts against a ~5,000 median). In such
--     a week the clock STOPS: nothing fades, nothing counts as quiet, and nothing
--     enters through the fast lane on a handful of posts. Its posts still add signal,
--     but SCALED by the week's coverage (posts / median) — a share computed on 153
--     posts made 2 posts of "mini sponge cake" look like a top-2 product — and the
--     status comparisons (rising vs last week, cooling vs the run's peak) use normal
--     weeks only.
--
--  3. FADE. score = sum over past weeks of signal x lambda^(normal weeks since), with
--     lambda = 0.5^(1 / social_trend_fade_half_life_weeks). At a 2-week half-life a
--     week's buzz counts 100%, ~71%, 50%, ~35%, 25%: a spike keeps a product up for
--     roughly 3-4 weeks after posting stops, and steady small posting keeps it up.
--
--  4. BOARD RULES (hysteresis — easy to get on, harder to fall off):
--       on the board  = top social_trend_top_n by faded score
--                     OR top social_trend_top_n by THIS week's rank (the fast lane: a
--                        new spike gets on immediately, before its fade score builds)
--                     OR it got on within the last social_trend_stay_window_weeks, is
--                        still in the top social_trend_stay_rank by faded score, and has
--                        had posts within social_trend_quiet_weeks_to_drop normal weeks.
--       status        = new / rising / steady / cooling, plus weeks_on_board and the
--                       best rank of the current run.
--
--  TWO SCOPES, shelf first (2026-10). Every product carries a label from
--  stg_mentionlytics__product_profile: branded / shelf (a product someone can STOCK)
--  or generic (a category, commodity or dish; also any product not labelled yet). The
--  two scopes are ranked SEPARATELY — fast lane, faded rank, stay-on rule each within
--  its own scope, with social_trend_top_n / _stay_rank for shelf and the smaller
--  social_trend_generic_top_n / _stay_rank for general — and board_rank then lists
--  every shelf product BEFORE every generic one. A broad staple ("fish sauce") can
--  stay on the board, but never above a stockable product ("lay's ice cream"), and the
--  report can drop generics and sort by scope_rank alone.
--
--  RISING LIST (separate): the product's average share over the last
--  social_trend_rising_recent_weeks normal weeks vs the social_trend_rising_baseline_weeks
--  before them. A staple talked about every week sits near 1x and never qualifies; a
--  product that is genuinely picking up does, which is the "potential trend" question
--  the weekly board could not answer.
--
-- Products, not names: int_social_concept_trends has already merged every spelling
-- into its canonical product (int_social_concept_canon), so a viral item's buzz is not
-- split across a dozen names before any of this runs.

with trends as (

    select * from {{ ref('int_social_concept_trends') }}

),

-- the board's weeks: the retained, complete weeks the trends model ranked
weeks as (

    select distinct week_start, week_end, year_week
    from trends

),

week_posts as (

    select cast(posted_week as date) as week_start, count(*) as posts
    from {{ ref('fct_social_mentions') }}
    group by 1

),

-- "usual" volume is the median of the PREVIOUS social_trend_coverage_baseline_weeks
-- weeks, not of the whole window: when the feed shrinks for good (the 2026-09 keyword
-- change left ~700 posts a week against ~4,000 before), the new size becomes the
-- baseline within a few weeks instead of reading as a data hole forever
baseline as (

    select
        w.week_start,
        {{ median('p.posts') }}                                         as median_posts
    from weeks as w
    left join week_posts as p
        on  p.week_start <  w.week_start
        and p.week_start >= {{ dbt.dateadd('day', -7 * var('social_trend_coverage_baseline_weeks'), 'w.week_start') }}
    group by 1

),

thin as (

    select
        w.week_start,
        w.week_end,
        w.year_week,
        coalesce(p.posts, 0)                                            as week_posts,
        b.median_posts,
        coalesce(coalesce(p.posts, 0) < {{ var('social_trend_low_coverage_ratio') }} * b.median_posts, false)
                                                                        as is_low_coverage
    from weeks as w
    left join week_posts as p
        on p.week_start = w.week_start
    left join baseline as b
        on b.week_start = w.week_start

),

coverage as (

    select
        *,
        -- low-coverage weeks in a row so far (the normal week before them starts a group)
        sum(case when is_low_coverage then 1 else 0 end) over (
            partition by low_group order by week_start
            rows between unbounded preceding and current row
        )                                                               as low_run
    from (
        select
            *,
            sum(case when is_low_coverage then 0 else 1 end)
                over (order by week_start rows between unbounded preceding and current row)
                                                                        as low_group
        from thin
    ) as g

),

-- the fade clock: counts every week except a PAUSED one. A low-coverage week pauses
-- it, but only social_trend_max_paused_weeks in a row: past that the silence is the
-- feed's new normal, and a product nobody posts about has to fade like any other
-- (before this cap, three thin weeks in four held a cake with no posts at #3 for a month)
clock as (

    select
        *,
        is_low_coverage and low_run <= {{ var('social_trend_max_paused_weeks') }}
                                                                        as is_fade_paused,
        sum(case when is_low_coverage and low_run <= {{ var('social_trend_max_paused_weeks') }}
                 then 0 else 1 end)
            over (order by week_start rows between unbounded preceding and current row)
                                                                        as normal_week_no
    from coverage

),

product_names as (

    select product_key, max(product_name) as product_name
    from {{ ref('int_social_concept_canon') }}
    group by 1

),

-- labels with a person's overrides applied and one spelling per brand
profiles as (

    select product_key, product_type, brand
    from {{ ref('int_social_product_labels') }}

),

products as (

    select
        t.concept_class,
        t.concept_norm,
        min(t.week_start)                                               as first_week,
        max(pf.product_type)                                            as product_type,
        max(pf.brand)                                                   as brand,
        case when max(pf.product_type) in ('branded', 'shelf')
             then 'shelf' else 'general' end                            as scope
    from trends as t
    left join profiles as pf
        on pf.product_key = t.concept_norm
    group by 1, 2

),

class_week_score as (

    select week_start, concept_class, sum(trend_score) as class_score
    from trends
    where trend_rank is not null
    group by 1, 2

),

-- one row per product per week from its first appearance; signal 0 where it had no row
spine as (

    select
        p.concept_class,
        p.concept_norm,
        p.scope,
        p.product_type,
        p.brand,
        k.week_start,
        k.week_end,
        k.year_week,
        k.week_posts,
        k.median_posts,
        k.is_low_coverage,
        k.is_fade_paused,
        k.normal_week_no,
        t.trend_rank,
        t.trend_score,
        t.mention_count,
        t.distinct_authors_adj,
        t.author_quality,
        -- repeat_poster rows carry no rank and so no signal: excluded, as on the weekly
        -- board. A low-coverage week's share is scaled by the week's coverage, so a
        -- share of a few hundred posts weighs what those posts are worth.
        case when t.trend_rank is not null and cw.class_score > 0
             then t.trend_score / cw.class_score
                  * case when k.is_low_coverage and k.median_posts > 0
                         then least(1.0, k.week_posts * 1.0 / k.median_posts)
                         else 1.0 end
             else 0 end                                                 as signal,
        t.trend_rank is not null                                        as has_posts
    from products as p
    inner join clock as k
        on k.week_start >= p.first_week
    left join trends as t
        on  t.week_start    = k.week_start
        and t.concept_class = p.concept_class
        and t.concept_norm  = p.concept_norm
    left join class_week_score as cw
        on  cw.week_start    = k.week_start
        and cw.concept_class = p.concept_class

),

faded as (

    select
        cur.concept_class,
        cur.concept_norm,
        cur.week_start,
        sum(past.signal * power({{ lam }}, cur.normal_week_no - past.normal_week_no))
                                                                        as faded_score,
        max(case when past.has_posts then past.normal_week_no end)      as last_posted_week_no,
        -- the previous NORMAL week's signal: status compares against it, never a
        -- low-coverage week's thin one
        max(case when not past.is_fade_paused
                  and past.normal_week_no = cur.normal_week_no - 1
                 then past.signal end)                                  as prev_normal_signal,
        -- Rising list inputs, over NORMAL weeks only
        sum(case when not past.is_fade_paused
                  and past.normal_week_no >  cur.normal_week_no - {{ var('social_trend_rising_recent_weeks') }}
                 then past.signal else 0 end)                           as recent_signal,
        sum(case when not past.is_fade_paused
                  and past.normal_week_no <= cur.normal_week_no - {{ var('social_trend_rising_recent_weeks') }}
                  and past.normal_week_no >  cur.normal_week_no - {{ var('social_trend_rising_recent_weeks') }}
                                                                - {{ var('social_trend_rising_baseline_weeks') }}
                 then past.signal else 0 end)                           as baseline_signal,
        sum(case when not past.is_fade_paused
                  and past.normal_week_no >  cur.normal_week_no - {{ var('social_trend_rising_recent_weeks') }}
                 then coalesce(past.mention_count, 0) else 0 end)       as recent_mentions,
        sum(case when not past.is_fade_paused
                  and past.normal_week_no >  cur.normal_week_no - {{ var('social_trend_rising_recent_weeks') }}
                 then coalesce(past.distinct_authors_adj, 0) else 0 end) as recent_authors
    from spine as cur
    inner join spine as past
        on  past.concept_class = cur.concept_class
        and past.concept_norm  = cur.concept_norm
        and past.week_start   <= cur.week_start
    group by 1, 2, 3

),

-- how many normal weeks the Rising baseline actually has behind each week (early weeks
-- have little history, and a baseline of one week is not a baseline)
baseline_depth as (

    select
        c.week_start,
        count(b.week_start)                                             as baseline_weeks
    from clock as c
    left join clock as b
        on  not b.is_fade_paused
        and b.normal_week_no <= c.normal_week_no - {{ var('social_trend_rising_recent_weeks') }}
        and b.normal_week_no >  c.normal_week_no - {{ var('social_trend_rising_recent_weeks') }}
                                               - {{ var('social_trend_rising_baseline_weeks') }}
    group by 1

),

ranked as (

    select
        s.*,
        f.faded_score,
        s.normal_week_no - coalesce(f.last_posted_week_no, s.normal_week_no)
                                                                        as quiet_weeks,
        f.recent_signal / {{ var('social_trend_rising_recent_weeks') }} as recent_share,
        f.baseline_signal / {{ var('social_trend_rising_baseline_weeks') }}
                                                                        as baseline_share,
        f.recent_mentions,
        f.recent_authors,
        f.prev_normal_signal,
        bd.baseline_weeks,
        -- all ranks are WITHIN the product's scope (shelf vs general)
        case when f.faded_score > 0 then
            row_number() over (
                partition by s.week_start, s.concept_class, s.scope
                order by f.faded_score desc, coalesce(s.mention_count, 0) desc, s.concept_norm
            ) end                                                       as faded_rank,
        case when s.has_posts then
            row_number() over (
                partition by s.week_start, s.concept_class, s.scope, s.has_posts
                order by s.signal desc, coalesce(s.mention_count, 0) desc, s.concept_norm
            ) end                                                       as week_scope_rank,
        case when s.scope = 'shelf' then {{ var('social_trend_top_n') }}
             else {{ var('social_trend_generic_top_n') }} end           as scope_top_n,
        case when s.scope = 'shelf' then {{ var('social_trend_stay_rank') }}
             else {{ var('social_trend_generic_stay_rank') }} end       as scope_stay_rank
    from spine as s
    inner join faded as f
        on  f.concept_class = s.concept_class
        and f.concept_norm  = s.concept_norm
        and f.week_start    = s.week_start
    inner join baseline_depth as bd
        on bd.week_start = s.week_start

),

entry as (

    select
        *,
        (faded_rank <= scope_top_n)
            or (not is_low_coverage and week_scope_rank <= scope_top_n)  as is_entering
    from ranked

),

membership as (

    select
        *,
        -- a week excluded as a repeat_poster is never on the board (the weekly board's
        -- guarantee, asserted on the mart): one account cannot hold a product up
        coalesce(author_quality, '') <> 'repeat_poster'
        and (coalesce(is_entering, false)
            or coalesce(
                max(case when is_entering then 1 else 0 end) over (
                    partition by concept_class, concept_norm
                    order by week_start
                    rows between {{ var('social_trend_stay_window_weeks') - 1 }} preceding and current row
                ) = 1
                and faded_rank <= scope_stay_rank
                and quiet_weeks < {{ var('social_trend_quiet_weeks_to_drop') }},
                false))                                                 as is_on_board,
        -- Rising list: picking up against its OWN history. A product with no baseline
        -- share at all is new to the feed and qualifies on volume alone.
        coalesce(
            recent_mentions >= {{ var('social_trend_rising_min_mentions') }}
            and recent_authors >= {{ var('social_trend_rising_min_authors') }}
            and baseline_weeks >= {{ var('social_trend_rising_min_baseline_weeks') }}
            and (baseline_share = 0
                 or recent_share >= {{ var('social_trend_rising_min_growth') }} * baseline_share),
            false)                                                      as is_rising_candidate
    from entry

),

runs as (

    select
        *,
        coalesce(lag(is_on_board) over (
            partition by concept_class, concept_norm order by week_start), false)
                                                                        as was_on_board
    from membership

),

streaks as (

    select
        *,
        sum(case when is_on_board and not was_on_board then 1 else 0 end) over (
            partition by concept_class, concept_norm
            order by week_start rows between unbounded preceding and current row
        )                                                               as run_no
    from runs

),

board as (

    select
        *,
        -- every shelf product before every generic one, each by faded score
        case when is_on_board then
            row_number() over (
                partition by week_start, concept_class, is_on_board
                order by case when scope = 'shelf' then 0 else 1 end,
                         faded_score desc, coalesce(mention_count, 0) desc, concept_norm
            ) end                                                       as board_rank,
        case when is_on_board then
            row_number() over (
                partition by week_start, concept_class, scope, is_on_board
                order by faded_score desc, coalesce(mention_count, 0) desc, concept_norm
            ) end                                                       as scope_rank,
        case when is_rising_candidate then
            row_number() over (
                partition by week_start, concept_class, is_rising_candidate
                order by case when scope = 'shelf' then 0 else 1 end,
                         recent_share desc, concept_norm
            ) end                                                       as rising_rank,
        case when is_on_board then
            sum(case when is_on_board then 1 else 0 end) over (
                partition by concept_class, concept_norm, run_no
                order by week_start rows between unbounded preceding and current row
            ) end                                                       as weeks_on_board,
        -- the run's peak over NORMAL weeks: a low-coverage week's share must not set a
        -- peak every later week then looks "cooling" against
        max(case when not is_low_coverage then signal end) over (
            partition by concept_class, concept_norm, run_no
            order by week_start rows between unbounded preceding and current row
        )                                                               as run_peak_signal
    from streaks

),

-- products that ever made the board or the Rising list keep every week of their
-- trajectory; the long tail that never did is dropped here
qualifying as (

    select distinct concept_class, concept_norm
    from board
    where is_on_board or is_rising_candidate

)

select
    b.week_start,
    b.week_end,
    b.year_week,
    b.concept_class,
    b.concept_norm,
    pn.product_name,
    b.product_type,
    b.brand,
    b.scope = 'shelf'                                                   as is_shelf_product,
    b.is_on_board,
    b.board_rank,
    b.scope_rank,
    case
        when not b.is_on_board                                    then null
        when not b.was_on_board                                   then 'new'
        -- a hole in the data says nothing about the product: hold it where it was
        when b.is_fade_paused                                     then 'steady'
        when b.quiet_weeks >= 1                                   then 'cooling'
        -- up 25%+ on the previous normal week; from nothing to something counts too
        when b.signal > 0 and b.signal >= 1.25 * coalesce(b.prev_normal_signal, 0) then 'rising'
        when b.signal < 0.5 * b.run_peak_signal                   then 'cooling'
        else 'steady'
    end                                                                 as board_status,
    b.weeks_on_board,
    min(b.board_rank) over (
        partition by b.concept_class, b.concept_norm, b.run_no
        order by b.week_start rows between unbounded preceding and current row
    )                                                                   as best_board_rank,
    b.faded_score,
    b.faded_rank,
    b.signal                                                            as week_signal,
    b.quiet_weeks,
    b.is_rising_candidate,
    b.rising_rank,
    b.recent_share,
    b.baseline_share,
    case when b.baseline_share > 0 then b.recent_share / b.baseline_share end
                                                                        as rising_growth,
    b.recent_mentions,
    b.week_posts,
    b.is_low_coverage,
    b.is_fade_paused
from board as b
inner join qualifying as q
    on  q.concept_class = b.concept_class
    and q.concept_norm  = b.concept_norm
left join product_names as pn
    on pn.product_key = b.concept_norm
