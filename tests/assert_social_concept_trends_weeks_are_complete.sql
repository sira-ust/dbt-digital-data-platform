-- assert_social_concept_trends_weeks_are_complete
--
-- Every ranked week must be a WHOLE calendar week that sits inside the collected
-- date range. The weekly export lands mid-week, so the newest calendar week is
-- usually a fragment (3 of 7 days when measured 2026-08-19) — and a fragment cannot
-- be ranked against a whole week: its counts are down by half for a reason that has
-- nothing to do with any trend, and every rank, share and week-over-week delta
-- derived from it would be wrong in the same direction. int_social_concept_trends
-- therefore drops incomplete weeks before anything is computed (see complete_weeks).
--
-- This replaces the is_partial_week column that used to carry the warning: an
-- invariant enforced by a test beats a flag every consumer has to remember to
-- honour. It is the thing that would catch the filter being dropped or moved below
-- the aggregation, which would quietly put a half-week back at the top of the board
-- where it looks exactly like a collapse in interest.
--
-- Fails (returns a row) for any week whose Sunday is past the last collected day, or
-- whose Monday precedes the first. Severity: error — a half-counted top week is the
-- single most misleading thing this table could publish.

with bounds as (

    select min(posted_date) as data_min_date, max(posted_date) as data_max_date
    from {{ ref('fct_social_mentions') }}

)

select
    t.week_start,
    t.week_end,
    b.data_min_date,
    b.data_max_date,
    count(*) as n_rows
from {{ ref('int_social_concept_trends') }} as t
cross join bounds as b
where t.week_end   > b.data_max_date
   or t.week_start < b.data_min_date
group by 1, 2, 3, 4
