-- assert_social_recommendations_aligned
--
-- mart_social_trending_items builds recommended_prtnums and recommended_items
-- with two array_agg()s over the same rows in ONE aggregate (see rec_agg), so
-- item name [i] is always the name of prtnum [i]. Neither DuckDB nor Databricks
-- specifies ordering BETWEEN two aggregates, so that alignment rests on both
-- buffers being filled row by row in a single pass. This asserts the observable
-- half of it: the arrays must be the same length. A length mismatch is the
-- realistic regression (one aggregate gaining or losing rows — e.g. someone
-- splits rec_agg into two CTEs, or joins the item master a second time); a pure
-- permutation of the same names can't be caught without a positional explode,
-- which needs an engine-specific posexplode/generate_subscripts.
--
-- Fails (returns a row) for any concept whose two recommendation arrays disagree
-- in length. Severity: error — the board would be attributing an item name to
-- the wrong part number, which is worse than showing nothing.

select
    concept_norm,
    {{ array_size('recommended_prtnums') }}  as n_prtnums,
    {{ array_size('recommended_items') }}    as n_items
from {{ ref('mart_social_trending_items') }}
where recommended_prtnums is not null
  and {{ array_size('recommended_prtnums') }} != {{ array_size('recommended_items') }}
