{{ config(tags=['promo']) }}
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
-- (scripts/draft_promo_terms.py, used so a new month can run before review) >
-- nothing. terms_source says which; 'missing' means draft_promo_terms.py has not
-- run for the item yet, and such an item cannot be searched.
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

)

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
    case when s.item_no is not null then s.brand_terms    else d.brand_terms    end as brand_terms,
    case when s.item_no is not null then s.product_terms  else d.product_terms  end as product_terms,
    case when s.item_no is not null then s.flavor_terms   else d.flavor_terms   end as flavor_terms,
    case when s.item_no is not null then s.negative_terms else d.negative_terms end as negative_terms,
    case when s.item_no is not null then s.search_queries else d.search_queries end as search_queries,
    coalesce(s.notes, d.notes)                               as terms_notes
from promo as p
left join nav as n
    on n.item_no = p.item_no
left join wms as w
    on w.prtnum = p.item_no
left join seed_terms as s
    on cast(s.item_no as {{ dbt.type_string() }}) = p.item_no
left join draft_terms as d
    on d.item_no = p.item_no
