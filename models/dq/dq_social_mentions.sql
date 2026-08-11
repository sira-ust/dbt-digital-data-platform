{{ config(tags=['social']) }}
-- DQ scorecard for Mentionlytics staging — one row per named check with a count,
-- percentage, and severity. Phase 1 covers only structural / non-LLM checks;
-- the spam / not-food-relevant / low-confidence / enrichment-coverage checks are
-- added in Phase 2 once mention_enrichment exists. Reads the deduped staging
-- model, plus the raw source once to measure how many rows the dedupe collapsed.
--
-- severity: 'warn' = investigate, 'info' = expected/known characteristic to
-- monitor, 'ok' = clean. Thresholds come from dbt_project.yml vars.

with mentions as (

    select * from {{ ref('stg_mentionlytics__mentions') }}

),

raw_src as (

    -- pre-dedupe row count across all weekly files
    select count(*) as raw_rows from {{ source('mentionlytics', 'mentions') }}

),

agg as (

    select
        count(*)                                                                    as total_rows,
        sum(case when mention_id is null then 1 else 0 end)                         as null_mention_id,
        sum(case when posted_at is null then 1 else 0 end)                          as null_posted_at,
        -- date granularity: posted on a day AFTER the export day is impossible;
        -- same-day is fine regardless of how precisely loaded_at was stamped
        sum(case when cast(posted_at as date) > cast(loaded_at as date) then 1 else 0 end) as future_posted_at,
        sum(case when posted_at < cast('{{ var("social_posted_at_floor_date") }}' as timestamp) then 1 else 0 end) as old_posted_at,
        sum(case when channel is null then 1 else 0 end)                           as null_channel,
        sum(case when sentiment is null then 1 else 0 end)                          as null_sentiment,
        sum(case when sentiment = 'positive' then 1 else 0 end)                     as positive_sentiment,
        sum(case when sentiment is not null then 1 else 0 end)                      as nonnull_sentiment,
        sum(case when country is null then 1 else 0 end)                            as null_country,
        -- Reddit "likes" is a net score that can legitimately go negative
        -- (downvotes); only flag negative likes off Reddit. Other metrics must
        -- never be negative on any channel.
        sum(case
                when (coalesce(likes,0) < 0 and channel <> 'Reddit')
                  or coalesce(comments,0) < 0 or coalesce(shares,0) < 0
                  or coalesce(views,0) < 0 or coalesce(impressions,0) < 0
                  or coalesce(followers_or_rank,0) < 0
                then 1 else 0 end)                                                  as negative_metric
    from mentions

),

checks as (

    select a.*, r.raw_rows from agg a cross join raw_src r

)

select 'null_mention_id' as check_name,
       case when null_mention_id > 0 then 'warn' else 'ok' end                      as severity,
       null_mention_id                                                              as flagged_rows,
       total_rows,
       round(100.0 * null_mention_id / nullif(total_rows, 0), 2)                    as flagged_pct,
       'mention_id is null — should be 0 (unique/not_null enforced in staging)'     as detail
from checks

union all
select 'duplicate_mention_id_collapsed',
       'info',
       raw_rows - total_rows,
       raw_rows,
       round(100.0 * (raw_rows - total_rows) / nullif(raw_rows, 0), 2),
       'raw rows minus deduped rows — duplicates collapsed by latest-loaded_at dedupe (expected across overlapping weekly files)'
from checks

union all
select 'null_posted_at',
       case when null_posted_at > 0 then 'warn' else 'ok' end,
       null_posted_at, total_rows,
       round(100.0 * null_posted_at / nullif(total_rows, 0), 2),
       'posted_at is null — cannot be time-bucketed'
from checks

union all
select 'future_posted_at',
       case when future_posted_at > 0 then 'warn' else 'ok' end,
       future_posted_at, total_rows,
       round(100.0 * future_posted_at / nullif(total_rows, 0), 2),
       'posted on a day after the export day (impossible) — check posted_at timezone / loaded_at'
from checks

union all
select 'implausible_old_posted_at',
       case when old_posted_at > 0 then 'warn' else 'ok' end,
       old_posted_at, total_rows,
       round(100.0 * old_posted_at / nullif(total_rows, 0), 2),
       'posted_at before {{ var("social_posted_at_floor_date") }} — suspect/garbage date'
from checks

union all
select 'null_channel',
       case when null_channel > 0 then 'warn' else 'ok' end,
       null_channel, total_rows,
       round(100.0 * null_channel / nullif(total_rows, 0), 2),
       'channel is null — should be 0 (not_null enforced in staging)'
from checks

union all
select 'null_sentiment',
       case when null_sentiment > 0 then 'info' else 'ok' end,
       null_sentiment, total_rows,
       round(100.0 * null_sentiment / nullif(total_rows, 0), 2),
       'sentiment label missing (minor)'
from checks

union all
select 'sentiment_skew_positive',
       case when 100.0 * positive_sentiment / nullif(nonnull_sentiment, 0)
                 > {{ var("social_sentiment_skew_warn_pct") }} then 'warn' else 'info' end,
       positive_sentiment, nonnull_sentiment,
       round(100.0 * positive_sentiment / nullif(nonnull_sentiment, 0), 2),
       'positive share of non-null sentiment — high skew suggests a default/import artifact, not real sentiment'
from checks

union all
select 'null_country',
       'info',
       null_country, total_rows,
       round(100.0 * null_country / nullif(total_rows, 0), 2),
       'country missing — geo insights are partial (known characteristic)'
from checks

union all
select 'negative_metric',
       case when negative_metric > 0 then 'warn' else 'ok' end,
       negative_metric, total_rows,
       round(100.0 * negative_metric / nullif(total_rows, 0), 2),
       'a comment/share/view/impression/followers_or_rank is negative, or likes negative off Reddit (Reddit net score may be negative)'
from checks
