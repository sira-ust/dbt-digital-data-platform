-- assert_promo_unmatched_fields_blank
--
-- An Unmatched row carries the promo item and nothing else: every match field is
-- blank, and it is the item's ONLY row. A half-filled Unmatched row (a stray link,
-- a leftover caption) or an Unmatched row next to a match would contradict itself
-- in the workbook and double-count the item on the Summary sheet.
--
-- Fails (returns a row) per offending row. Severity: error.

select m.promo_month, m.promo_sheet, m.row_order, m.item_no
from {{ ref('mart_promo_social_match') }} as m
where m.match_status = 'Unmatched'
  and (
        m.matched_content_item is not null or m.channel is not null or m.profile is not null
     or m.post_date is not null or m.engagement_text is not null or m.caption is not null
     or m.link is not null or m.source is not null or m.match_note is not null
     or m.match_rank <> 1
     or exists (
            select 1 from {{ ref('mart_promo_social_match') }} as o
            where o.promo_month = m.promo_month and o.promo_sheet = m.promo_sheet
              and o.row_order = m.row_order and o.match_status <> 'Unmatched'
        )
  )
