-- LLM-drafted terms, one row per item_no (latest draft wins). Only used for items
-- with no reviewed row in seed_promo_item_terms — see int_promo_items_enriched.

with source as (

    select * from {{ source('promo', 'item_terms_draft') }}

),

typed as (

    select
        nullif(trim(cast(item_no as {{ dbt.type_string() }})), '')         as item_no,
        nullif(trim(cast(brand as {{ dbt.type_string() }})), '')           as brand,
        nullif(trim(cast(product as {{ dbt.type_string() }})), '')         as product,
        nullif(trim(cast(flavor_variant as {{ dbt.type_string() }})), '')  as flavor_variant,
        nullif(trim(cast(pack_format as {{ dbt.type_string() }})), '')     as pack_format,
        lower(trim(cast(is_branded as {{ dbt.type_string() }}))) = 'true'  as is_branded,
        nullif(trim(cast(brand_terms as {{ dbt.type_string() }})), '')     as brand_terms,
        nullif(trim(cast(product_terms as {{ dbt.type_string() }})), '')   as product_terms,
        nullif(trim(cast(flavor_terms as {{ dbt.type_string() }})), '')    as flavor_terms,
        nullif(trim(cast(negative_terms as {{ dbt.type_string() }})), '')  as negative_terms,
        nullif(trim(cast(search_queries as {{ dbt.type_string() }})), '')  as search_queries,
        nullif(trim(cast(notes as {{ dbt.type_string() }})), '')           as notes,
        try_cast(drafted_at as timestamp)                                   as drafted_at,
        nullif(trim(cast(model_version as {{ dbt.type_string() }})), '')   as model_version
    from source

),

numbered as (

    select *, row_number() over (partition by item_no order by drafted_at desc) as _rn
    from typed
    where item_no is not null

)

select
    item_no, brand, product, flavor_variant, pack_format, is_branded,
    brand_terms, product_terms, flavor_terms, negative_terms, search_queries,
    notes, drafted_at, model_version
from numbered
where _rn = 1
