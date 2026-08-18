-- assert_social_concept_trends_mention_share_sums
--
-- mention_share is a concept's (concept, mention) pairs divided by ALL pairs in the
-- same as-of window and class, which is what makes it immune to corpus growth (and
-- therefore the one rise signal worth trusting — see int_social_concept_trends on
-- why is_rising isn't). That property only holds if the denominator is scoped to the
-- same (week_start, concept_class) as the numerator, so within a week and class the
-- shares must sum to at most 1.
--
-- This is the guard for a specific, quiet failure: drop week_start from the
-- window_totals join and every share comes out ~history_weeks times too small.
-- Nothing else notices — the values still look like plausible small percentages,
-- rankings are unaffected (trend_score doesn't use share), and no not_null or range
-- test fires. The sum is the only place it shows.
--
-- Sums to <= 1 rather than = 1 because social_trend_min_mentions drops sub-floor
-- concepts AFTER the denominator is computed, so a week legitimately sums to less.
-- The epsilon absorbs float division only.
--
-- Severity: error — a broken share silently misleads the "what's rising" read.

select
    week_start,
    concept_class,
    sum(mention_share) as total_share
from {{ ref('int_social_concept_trends') }}
group by 1, 2
having sum(mention_share) > 1.000001
