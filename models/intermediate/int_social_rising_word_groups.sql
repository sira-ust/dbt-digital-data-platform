{{ config(tags=['social']) }}
{% set base_weeks = var('social_words_baseline_weeks') %}
{% set cap = var('social_words_account_cap') %}
-- int_social_rising_word_groups — step 1 of 3 of the rising-words list: each week's
-- candidate RISING WORDS, with the spelling group each one belongs to. One row per
-- (week, word). The rules (shares not counts, the account cap, the noise filters) are
-- described in mart_social_rising_words; int_social_rising_stories (step 2) merges
-- these words into stories.
--
-- WHY A TABLE. Built as one query, the list reused its own steps so many times that
-- Databricks could not finish compiling it (2026-11-04). Saved here and in
-- int_social_rising_stories, every query stays small; the rows are the same.

with weeks as (

    select distinct week_start
    from {{ ref('int_social_trend_board') }}

),

hits as (

    select mention_id, week_start, thread_key, owner, term
    from {{ ref('int_social_post_words') }}
    where term is not null

),

posts as (

    select distinct mention_id, week_start, thread_key, link, views, market
    from {{ ref('int_social_post_words') }}

),

week_threads as (

    select week_start, count(distinct thread_key) as week_threads
    from posts
    group by 1

),

baseline_size as (

    select wk.week_start, sum(wt.week_threads) as base_threads
    from weeks as wk
    inner join week_threads as wt
        on wt.week_start between cast({{ dbt.dateadd('day', -7 * base_weeks, 'wk.week_start') }} as date)
                             and cast({{ dbt.dateadd('day', -7, 'wk.week_start') }} as date)
    group by 1

),

-- each word's posts per week; an account counts at most `cap` times
word_owner_week as (

    select term, week_start, owner, count(distinct thread_key) as threads
    from hits
    group by 1, 2, 3

),

word_week as (

    select
        term,
        week_start,
        sum(least(threads, {{ cap }}))                                  as posts,
        sum(threads)                                                    as raw_posts,
        count(*)                                                        as accounts
    from word_owner_week
    group by 1, 2

),

word_baseline as (

    select wk.week_start, ww.term, sum(ww.posts) as base_posts
    from weeks as wk
    inner join word_week as ww
        on ww.week_start between cast({{ dbt.dateadd('day', -7 * base_weeks, 'wk.week_start') }} as date)
                             and cast({{ dbt.dateadd('day', -7, 'wk.week_start') }} as date)
    group by 1, 2

),

scored as (

    select
        ww.week_start,
        ww.term,
        ww.posts,
        ww.raw_posts,
        ww.accounts,
        1000.0 * ww.posts / wt.week_threads                             as per_k,
        1000.0 * coalesce(wb.base_posts, 0) / bs.base_threads           as base_per_k
    from weeks as wk
    inner join word_week as ww
        on ww.week_start = wk.week_start
    inner join week_threads as wt
        on wt.week_start = wk.week_start
    inner join baseline_size as bs
        on bs.week_start = wk.week_start
    left join word_baseline as wb
        on wb.week_start = wk.week_start and wb.term = ww.term
    where bs.base_threads > 0

),

cands as (

    select
        week_start,
        term,
        posts                                                           as n_posts,
        accounts,
        per_k,
        base_per_k,
        (per_k + 0.5) / (base_per_k + 0.5)                              as growth
    from scored
    where posts >= {{ var('social_rising_words_min_posts') }}
      and accounts >= {{ var('social_rising_words_min_accounts') }}
      and raw_posts <= {{ var('social_rising_words_max_posts_per_account') }} * accounts
      and base_per_k <= {{ var('social_rising_words_max_base_per_k') }}
      and (per_k + 0.5) / (base_per_k + 0.5) >= {{ var('social_rising_words_min_growth') }}

),

{{ social_word_groups('cands', ['week_start'], 'rw') }}

select
    c.week_start,
    c.term,
    c.n_posts,
    c.accounts,
    c.per_k,
    c.base_per_k,
    c.growth,
    g.grp
from cands as c
inner join rw_grp as g
    on g.week_start = c.week_start and g.term = c.term
