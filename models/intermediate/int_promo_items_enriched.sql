{{ config(tags=['promo']) }}
{#- UST's own-brand names (var promo_brand_codes, own_brand: true), lowercased with
    spaces removed, so "HB", "Honey Bee" and October's reviewed "Chuon Chuon" all
    land on their brand. -#}
{%- set own_brand_aliases = [] -%}
{%- for c in var('promo_brand_codes', []) if c.own_brand -%}
    {%- for a in c.aliases -%}
        {%- do own_brand_aliases.append(a | lower | replace(' ', '')) -%}
    {%- endfor -%}
{%- endfor %}
-- int_promo_items_enriched — one row per promo-workbook row, joined to what the
-- company knows about the item and to the terms the matcher searches with.
--
-- WHY THE ITEM MASTER IS NOT ENOUGH. NAV has no brand column, and the promo
-- description is uppercase and cut at 30 characters ("COCONUT MILK DRINK (LESS
-- SUGAR"). NAV's full_description / flavor / package attributes are filled for
-- only ~10 of October's 52 items, but where they exist they settle things the
-- promo text cannot ("HB ORANGE DRINK" is HONEYBEE). So brand, product, flavor and
-- the search terms come from seed_promo_item_terms — a reviewed, committed file —
-- and the catalog fields ride along as evidence for the reviewer and the AI judge.
--
-- TERMS SOURCE, in order: the seed (reviewed by a person) > the latest LLM draft
-- (scripts/promo/draft_promo_terms.py, used so a new month can run before review) >
-- nothing. terms_source says which; 'missing' means draft_promo_terms.py has not
-- run for the item yet, and such an item cannot be searched.
--
-- PRODUCT CARDS (stg_promo__product_cards, from the item's photo and description
-- file): the card's pack-text search phrases go FIRST in search_queries, and the
-- flavor / product spellings read off the pack are ADDED to flavor_terms /
-- product_terms (only where the item already has terms of that kind, so a card never
-- turns a flavorless item into one that needs a flavor). The card itself rides along
-- as card_* columns, for the judge and the TikTok / RedNote lists. No card, no change.
--
-- EVERY PROMO ROW IS KEPT. An item that fails to join NAV or the WMS stays, with
-- nav_match / wms_match = false — the output must list all of them.

with promo as (

    select * from {{ ref('stg_promo__items') }}

),

nav as (

    select * from {{ ref('stg_nav__items') }}

),

-- one WMS row per item code (two client ids would fan out the promo row);
-- ordered so the pick is deterministic, same as dim_items
wms as (

    select prtnum, item_name
    from (
        select
            prtnum,
            item_name,
            row_number() over (partition by prtnum order by prt_client_id) as _rn
        from {{ ref('int_jdawms_items') }}
    ) as w
    where _rn = 1

),

seed_terms as (

    select * from {{ ref('seed_promo_item_terms') }}

),

draft_terms as (

    select * from {{ ref('stg_promo__item_terms_draft') }}

),

cards as (

    select * from {{ ref('stg_promo__product_cards') }}

),

joined as (

select
    p.promo_month,
    p.promo_sheet,
    p.sheet_order,
    p.row_order,
    p.item_no,
    p.promo_description,
    p.promo_size,
    p.promo_code,
    p.vendor_no,
    p.promo_starts_on,
    p.promo_ends_on,
    p.source_file,

    -- from the monthly INPUT file's description columns (null for the original layout)
    p.brand_stated,
    p.short_description,
    p.selling_points,
    p.detail_notes,
    p.origin_code,
    p.photo_path,

    -- what the catalog says (evidence; often null)
    n.item_description                                       as nav_description,
    n.item_full_description,
    n.item_body_description,
    n.attribute_flavor,
    n.attribute_package,
    n.item_category_code,
    n.product_group_code,
    -- '1' is NAV's placeholder for "no barcode", not a barcode
    case when n.upc_code = '1' then null else n.upc_code end as upc_code,
    n.country_of_origin,
    w.item_name                                              as wms_item_name,
    n.item_no is not null                                    as nav_match,
    w.prtnum is not null                                     as wms_match,

    -- what the matcher searches with
    case
        when s.item_no is not null then 'seed'
        when d.item_no is not null then 'draft'
        else 'missing'
    end                                                      as terms_source,
    s.review_status,
    coalesce(s.brand,          d.brand)                      as brand,
    coalesce(s.product,        d.product)                    as product,
    coalesce(s.flavor_variant, d.flavor_variant)             as flavor_variant,
    coalesce(s.pack_format,    d.pack_format)                as pack_format,
    coalesce(s.is_branded,     d.is_branded, false)          as is_branded,
    -- a frozen item (a frozen code such as FZ / D FZ / FROZEN sets pack_format
    -- frozen when terms are drafted): with no brand it is still scraped, as a frozen
    -- product, and its scraped videos are Close at best (no brand to match)
    coalesce(coalesce(s.pack_format, d.pack_format) = 'frozen', false) as is_frozen,
    -- OWN BRANDS ARE MATCHED AND ALWAYS SCRAPED: like any brand they are matched
    -- against Mentionlytics, but they also go to YouTube and the TikTok list even
    -- when Mentionlytics found posts, because Mentionlytics tracks two broad F&B
    -- keyword sets that rarely name UST's own brands.
    {% if own_brand_aliases -%}
    coalesce(lower(replace(coalesce(s.brand, d.brand), ' ', '')) in (
        {%- for a in own_brand_aliases %}'{{ a }}'{{ ', ' if not loop.last }}{% endfor -%}
    ), false)
    {%- else -%}
    false
    {%- endif %}                                             as is_own_brand,
    case when s.item_no is not null then s.brand_terms    else d.brand_terms    end as brand_terms,
    -- the seed's / draft's terms, before the card (final columns below)
    case when s.item_no is not null then s.product_terms  else d.product_terms  end as base_product_terms,
    case when s.item_no is not null then s.flavor_terms   else d.flavor_terms   end as base_flavor_terms,
    case when s.item_no is not null then s.negative_terms else d.negative_terms end as negative_terms,
    case when s.item_no is not null then s.search_queries else d.search_queries end as base_search_queries,
    coalesce(s.notes, d.notes)                               as terms_notes,

    -- the product card
    c.item_no is not null                                    as has_card,
    c.brand_on_pack                                          as card_brand_on_pack,
    c.product_on_pack                                        as card_product_on_pack,
    c.flavor_on_pack                                         as card_flavor_on_pack,
    c.pack                                                   as card_pack,
    c.market                                                 as card_market,
    c.look                                                   as card_look,
    c.pack_text                                              as card_pack_text,
    c.lookalikes                                             as card_lookalikes,
    c.search_phrases                                         as card_search_phrases,
    c.flavor_terms                                           as card_flavor_terms,
    c.product_terms                                          as card_product_terms,
    c.drafted_at                                             as card_drafted_at
from promo as p
left join nav as n
    on n.item_no = p.item_no
left join wms as w
    on w.prtnum = p.item_no
left join seed_terms as s
    on cast(s.item_no as {{ dbt.type_string() }}) = p.item_no
left join draft_terms as d
    on d.item_no = p.item_no
left join cards as c
    on c.item_no = p.item_no

)

select
    *,
    -- the card's spellings join the terms only where the item has terms of that kind
    case when base_product_terms is not null
         then nullif(concat_ws('|', base_product_terms, card_product_terms), '') end as product_terms,
    case when base_flavor_terms is not null
         then nullif(concat_ws('|', base_flavor_terms, card_flavor_terms), '') end   as flavor_terms,
    -- the card's pack-text phrases first: the searches take the first few
    nullif(concat_ws('|', card_search_phrases, base_search_queries), '')          as search_queries
from joined
