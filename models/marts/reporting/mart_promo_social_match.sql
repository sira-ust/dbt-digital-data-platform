{{ config(tags=['promo']) }}
-- mart_promo_social_match — the monthly "Promo vs Social Listening" sheet as a
-- table: AT LEAST ONE ROW PER PROMO-WORKBOOK ROW, in workbook order, with each
-- matched post or video on its own consecutive row. scripts/
-- export_promo_social_match.py writes the Excel workbook straight from this.
--
-- Which rows an item gets, in order of precedence:
--   1. Social Listening Exact posts. An item with any Exact post shows ONLY
--      those: a confirmed post makes "same brand, flavor unknown" noise, and it
--      keeps every item to one status so the Summary sheet's per-status item
--      counts add up to the item count.
--   2. otherwise Social Listening Close posts;
--   3. otherwise up to 3 verified YouTube videos (Source = Scraped) — only ever
--      for an item with NO social-listening row, which is also the only kind of
--      item youtube_search.py searches;
--   4. otherwise one row with status Unmatched and every match field blank.
-- TikTok is added after this, by hand in Claude in Chrome, from the workbook's
-- TikTok Search List sheet — see models/docs/_promo_social.md.

with items as (

    select * from {{ ref('int_promo_items_enriched') }}

),

social as (

    select
        s.*,
        max(case when s.match_status = 'Exact' then 1 else 0 end)
            over (partition by s.promo_month, s.promo_sheet, s.row_order) as item_has_exact
    from {{ ref('int_promo_social_matches') }} as s

),

social_kept as (

    select
        promo_month, promo_sheet, row_order, match_status, matched_content_item, channel,
        profile, posted_on, views, likes, total_engagement, caption, link, source,
        judge_reason, keyword_level, brand_hit, product_hit, flavor_hit, match_text,
        judge_model,
        mention_id,
        cast(null as {{ dbt.type_string() }})  as video_id,
        cast(null as integer)                  as scraped_rank
    from social
    where match_status = 'Exact' or item_has_exact = 0

),

scraped as (

    select
        c.promo_month, c.promo_sheet, c.row_order, c.match_status, c.matched_content_item,
        c.channel, c.profile, c.posted_on, c.views, c.likes,
        cast(null as bigint)                   as total_engagement,
        c.caption, c.link, c.source, c.judge_reason, c.keyword_level, c.brand_hit,
        c.product_hit, c.flavor_hit, c.match_text, c.judge_model,
        cast(null as bigint)                   as mention_id,
        c.video_id,
        c.scraped_rank
    from {{ ref('int_promo_scraped_matches') }} as c
    where not exists (
        select 1 from social as s
        where s.promo_month = c.promo_month
          and s.promo_sheet = c.promo_sheet
          and s.row_order   = c.row_order
    )

),

matches as (

    select * from social_kept
    union all
    select * from scraped

),

joined as (

    select
        i.promo_month,
        i.promo_sheet,
        i.sheet_order,
        i.row_order,
        i.item_no,
        i.promo_description,
        i.promo_size,
        i.promo_code,
        i.brand,
        i.is_branded,
        i.terms_source,
        coalesce(i.flavor_terms, '') <> ''                       as item_requires_flavor,
        coalesce(m.match_status, 'Unmatched')                    as match_status,
        m.matched_content_item,
        m.channel,
        m.profile,
        m.posted_on,
        m.views,
        m.likes,
        m.total_engagement,
        m.caption,
        m.link,
        m.source,
        m.judge_reason,
        m.keyword_level,
        m.brand_hit,
        m.product_hit,
        m.flavor_hit,
        m.match_text,
        m.judge_model,
        m.mention_id,
        m.video_id,
        m.scraped_rank
    from items as i
    left join matches as m
        on  m.promo_month = i.promo_month
        and m.promo_sheet = i.promo_sheet
        and m.row_order   = i.row_order

)

select
    promo_month,
    promo_sheet,
    sheet_order,
    row_order,
    row_number() over (
        partition by promo_month, promo_sheet, row_order
        order by
            case match_status when 'Exact' then 0 when 'Close' then 1 else 2 end,
            coalesce(scraped_rank, 0),
            coalesce(views, 0) desc,
            coalesce(likes, 0) desc,
            coalesce(total_engagement, 0) desc,
            posted_on desc,
            coalesce(cast(mention_id as {{ dbt.type_string() }}), video_id)
    )                                                            as match_rank,
    item_no,
    cast(item_no as bigint)                                      as item_no_int,
    promo_description,
    promo_size,
    promo_code,
    brand,
    is_branded,
    terms_source,
    match_status,
    matched_content_item,
    channel,
    profile,
    cast(posted_on as {{ dbt.type_string() }})                   as post_date,
    -- always carries its unit; YouTube always reports views, a social post only
    -- the metrics the platform gave Mentionlytics
    case
        when match_status = 'Unmatched' then null
        else coalesce(nullif(concat_ws(', ',
            case when views > 0 or source = 'Scraped'
                 then concat({{ format_count('coalesce(views, 0)') }}, ' views') end,
            case when likes > 0 then concat({{ format_count('likes') }}, ' likes') end,
            case when total_engagement > 0
                 then concat({{ format_count('total_engagement') }}, ' total engagement') end
        ), ''), 'Not reported')
    end                                                          as engagement_text,
    caption,
    link,
    source,
    case
        when match_status = 'Unmatched' then null
        when source = 'Scraped' then concat('Brand + product/flavor named in video. ', coalesce(judge_reason, ''))
        when match_status = 'Exact' then concat('Brand, product and flavor match. ', coalesce(judge_reason, ''))
        else concat('Same brand/product line; flavor or variant not confirmed. ', coalesce(judge_reason, ''))
    end                                                          as match_note,
    views,
    likes,
    total_engagement,
    mention_id,
    video_id,
    item_requires_flavor,
    keyword_level,
    brand_hit,
    product_hit,
    flavor_hit,
    match_text,
    judge_model
from joined
