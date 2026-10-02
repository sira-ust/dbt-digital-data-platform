-- assert_promo_scraped_only_without_social
--
-- Source rule: a Scraped (YouTube) row may only exist for an item that has NO
-- Social Listening row. The search exists to fill gaps in social listening, and the
-- workbook reads one item as one story — a scraped video sitting under a social
-- listening match would make two "best evidence" claims for the same item.
-- youtube_search.py only searches unmatched items and the mart filters again; this
-- fails if either gate is ever lost.
--
-- Fails (returns a row) per item breaking the rule. Severity: error.

select promo_month, promo_sheet, row_order, item_no
from {{ ref('mart_promo_social_match') }}
group by promo_month, promo_sheet, row_order, item_no
having sum(case when source = 'Scraped' then 1 else 0 end) > 0
   and sum(case when source = 'Social Listening' then 1 else 0 end) > 0
