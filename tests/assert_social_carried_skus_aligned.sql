-- assert_social_carried_skus_aligned
--
-- Two assertions on mart_social_trending_items.carried_*, both cheap and both
-- guarding a silent-corruption failure mode:
--
--   1. LENGTH PARITY. The pair is built with two array_agg()s over the same rows
--      in ONE aggregate (see carried_sku_agg), so item name [i] belongs to prtnum [i].
--      Neither engine specifies ordering BETWEEN two aggregates, so that rests on
--      both buffers being filled in a single pass — see
--      assert_social_recommendations_aligned for the full argument.
--
--   2. ONLY ON A CARRIED MATCH. carried_items means "the SKUs of this product we
--      stock". On a row where we carry nothing there is no such set, so a populated
--      array there is meaningless rather than merely untidy. Holds by construction
--      (alt_matched filters result_type_adj = 'carried'), which is exactly why it is
--      worth pinning: the filter is one line, three CTEs away from the output.
--
--   3. THE GUARD IS NOT BITING. social_carried_skus_max exists to stop a runaway
--      array, not to choose what to display — the column answers "what do we carry",
--      so a truncated list is a WRONG answer, not a short one. If a real product
--      family ever reaches the ceiling this fails rather than silently publishing a
--      partial list.
--
--   4. THE MATCH IS IN ITS OWN LIST. matched_prtnum is the representative pick, not
--      something the rest are alternatives to, so it must appear among them — and
--      first. A row whose carried_prtnums omits its own matched_prtnum means the
--      duplicate-name collapse dropped it (it keeps is_matched first precisely so
--      that cannot happen).
--
-- Fails (returns a row) on either. Severity: error.

select
    concept_key,
    result_type,
    carried_sku_count,
    {{ array_size('carried_prtnums') }}  as n_prtnums,
    {{ array_size('carried_items') }}    as n_items
from {{ ref('mart_social_trending_items') }}
where carried_prtnums is not null
  and (
        {{ array_size('carried_prtnums') }} != {{ array_size('carried_items') }}
     or result_type != 'carried'
     or not {{ array_contains('carried_prtnums', 'matched_prtnum') }}
     or carried_sku_count >= {{ var('social_carried_skus_max') }}
  )
