-- assert_promo_every_item_in_mart
--
-- Coverage: every row of the promo workbook appears in mart_promo_social_match at
-- least once — matched or as an explicit Unmatched row. The output's job is to
-- answer "what about item X?" for EVERY promo item; one silently missing (a join
-- that dropped it, a status the mart did not expect) would read as "not on promo".
--
-- Checked by workbook position, not item_no, so an item listed on both sheets must
-- appear twice. October: 52 rows in, 52 distinct positions out.
--
-- Fails (returns a row) for each promo row with no mart row. Severity: error.

select p.promo_month, p.promo_sheet, p.row_order, p.item_no
from {{ ref('stg_promo__items') }} as p
left join {{ ref('mart_promo_social_match') }} as m
    on  m.promo_month = p.promo_month
    and m.promo_sheet = p.promo_sheet
    and m.row_order   = p.row_order
where m.item_no is null
