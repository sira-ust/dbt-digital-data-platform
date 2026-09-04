-- assert_social_nearest_only_when_none
--
-- nearest_* is the "we found something but aren't confident" column, and its whole
-- meaning depends on it being empty wherever a real match IS shown — otherwise a
-- reader sees a promote_now row with a second, weaker list beside it and has no way
-- to tell which one the board is actually asserting.
--
-- The invariant holds by construction today: nearest_raw reads only rows that are
-- raw_result_type = 'none' or _low_conf, and BOTH map to result_type_adj = 'none'
-- (_low_conf is only ever true for carried/substitute/basket). This test pins that
-- reasoning down, because it is a two-step argument across two CTEs and the obvious
-- future edit — sourcing nearest_* from anything else, or relaxing the floor — breaks
-- it silently.
--
-- Fails (returns a row) for any row carrying nearest items without result_type
-- 'none'. Severity: error.

select
    concept_key,
    result_type,
    nearest_prtnums
from {{ ref('mart_social_trending_items') }}
where nearest_prtnums is not null
  and result_type != 'none'
