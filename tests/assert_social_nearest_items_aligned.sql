-- assert_social_nearest_items_aligned
--
-- The nearest_* pair in mart_social_trending_items is built the same way as the
-- recommended_* pair — two array_agg()s over the same rows in ONE aggregate (see
-- nearest_agg), so item name [i] is always the name of prtnum [i]. Neither DuckDB
-- nor Databricks specifies ordering BETWEEN two aggregates, so that alignment
-- rests on both buffers being filled row by row in a single pass. This asserts
-- the observable half: the arrays must be the same length. See
-- assert_social_recommendations_aligned for the full argument, including why a
-- pure permutation can't be caught without an engine-specific posexplode.
--
-- Fails (returns a row) for any concept whose two nearest arrays disagree in
-- length. Severity: error — the board would be attributing an item name to the
-- wrong part number, which is worse than showing nothing.

select
    concept_norm,
    {{ array_size('nearest_prtnums') }}  as n_prtnums,
    {{ array_size('nearest_items') }}    as n_items
from {{ ref('mart_social_trending_items') }}
where nearest_prtnums is not null
  and {{ array_size('nearest_prtnums') }} != {{ array_size('nearest_items') }}
