{{ config(tags=['social']) }}
-- Lossless staging for the product labels (scripts/canonicalize_concepts.py
-- --profile-products): one row per product_key, latest label at the highest prompt
-- version wins. Cast + dedupe only.

with source as (

    select * from {{ source('mentionlytics', 'product_profile') }}

),

typed as (

    select
        nullif(trim(cast(product_key as {{ dbt.type_string() }})), '')     as product_key,
        nullif(trim(cast(product_name as {{ dbt.type_string() }})), '')    as product_name,
        lower(trim(cast(product_type as {{ dbt.type_string() }})))         as product_type,
        nullif(trim(cast(brand as {{ dbt.type_string() }})), '')           as brand,
        try_cast(profiled_at as timestamp)                                  as profiled_at,
        nullif(trim(cast(model_version as {{ dbt.type_string() }})), '')   as model_version
    from source

),

numbered as (

    select
        *,
        row_number() over (
            partition by product_key
            order by model_version desc, profiled_at desc
        ) as _rn
    from typed
    where product_key is not null and product_type in ('branded', 'shelf', 'generic')

)

select product_key, product_name, product_type, brand, profiled_at, model_version
from numbered
where _rn = 1
