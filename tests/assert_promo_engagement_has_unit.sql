-- assert_promo_engagement_has_unit
--
-- "Views / Engagement" always says what the number is: "31,939 views, 88 likes",
-- "3,706 likes", or "Not reported" — never a bare number. YouTube reports views and
-- TikTok likes, and a reader comparing rows across platforms must never take one
-- for the other.
--
-- Fails (returns a row) for a matched row whose text has no unit. Severity: error.

select promo_month, promo_sheet, row_order, item_no, source, engagement_text
from {{ ref('mart_promo_social_match') }}
where match_status <> 'Unmatched'
  and (
        engagement_text is null
     or not (engagement_text = 'Not reported'
             or engagement_text like '% views%'
             or engagement_text like '% likes%'
             or engagement_text like '% total engagement%')
  )
