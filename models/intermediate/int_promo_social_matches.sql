{{ config(tags=['promo']) }}
-- int_promo_social_matches — every Mentionlytics post the AI judge kept for a
-- promo item, one row per (promo row, post). Source = 'Social Listening'.
--
-- STATUS = keyword evidence x judge verdict (same rule as
-- promo_common.final_status): Exact only when the judge says exact AND the
-- brand + product (+ flavor) terms were all found in the text; a judge 'exact'
-- over 'close' keywords stays Close. Rejected pairs are dropped here — they stay
-- in stg_promo__social_judgments for audit.
--
-- EVERY MATCHED POST IS ITS OWN ROW (the spec: "don't collapse to one"). The
-- item-level rule that an item with an Exact post shows only its Exact posts is
-- applied in the mart, not here, so this model still answers "what did the judge
-- keep".

with judgments as (

    select * from {{ ref('stg_promo__social_judgments') }}
    where verdict in ('exact', 'close')

),

mentions as (

    select * from {{ ref('stg_mentionlytics__mentions') }}

),

items as (

    select promo_month, promo_sheet, row_order, item_no
    from {{ ref('int_promo_items_enriched') }}

)

select
    i.promo_month,
    i.promo_sheet,
    i.row_order,
    i.item_no,
    m.mention_id,
    case
        when j.verdict = 'exact' and j.keyword_level = 'exact' then 'Exact'
        else 'Close'
    end                                                          as match_status,
    j.matched_content_item,
    -- Mentionlytics writes 'Youtube'; the workbook says YouTube, and a Shorts
    -- link is its own channel there
    case
        when m.channel = 'Youtube' and m.link like '%/shorts/%' then 'YouTube Shorts'
        when m.channel = 'Youtube'  then 'YouTube'
        when m.channel = 'Linkedin' then 'LinkedIn'
        else m.channel
    end                                                          as channel,
    m.profile,
    cast(m.posted_at as date)                                    as posted_on,
    m.views,
    m.likes,
    m.total_engagement,
    trim(concat_ws(' ', m.title, m.content))                     as caption,
    m.link,
    'Social Listening'                                           as source,
    j.reason                                                     as judge_reason,
    j.keyword_level,
    j.brand_hit,
    j.product_hit,
    j.flavor_hit,
    j.match_text,
    j.judge_model
from judgments as j
inner join items as i
    on i.item_no = j.item_no
inner join mentions as m
    on m.mention_id = j.mention_id
