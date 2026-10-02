-- assert_promo_exact_has_terms
--
-- "Exact means exact": no Exact row unless the brand term, the product term and —
-- when the item has flavor terms — the flavor term were all found in the post's
-- own text (the caption for social listening; title + description + tags for
-- YouTube). The AI judge can lower a match to Close but must never be able to
-- create an Exact on its own say-so; this is the guard on that rule.
--
-- Each hit is re-checked as a plain substring of match_text, the normalised text
-- the matcher searched (scripts/promo_common.match_text), so the test does not
-- just trust that a hit column is non-null.
--
-- Fails (returns a row) for each Exact row missing evidence. Severity: error.

select promo_month, promo_sheet, row_order, item_no, source, link,
       brand_hit, product_hit, flavor_hit
from {{ ref('mart_promo_social_match') }}
where match_status = 'Exact'
  and (
        brand_hit is null or instr(match_text, brand_hit) = 0
     or product_hit is null or instr(match_text, product_hit) = 0
     or (item_requires_flavor and (flavor_hit is null or instr(match_text, flavor_hit) = 0))
     or keyword_level <> 'exact'
  )
