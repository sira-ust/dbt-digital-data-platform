{{ config(tags=['social']) }}
-- Lossless staging for the canonical-product map (scripts/canonicalize_concepts.py).
-- One row per (concept_class, concept_norm): the source is append-only, so the latest
-- canonicalisation at the highest prompt version wins. Cast + dedupe only.

with source as (

    select * from {{ source('mentionlytics', 'concept_canon') }}

),

typed as (

    select
        nullif(trim(cast(concept_class as {{ dbt.type_string() }})), '')    as concept_class,
        nullif(trim(cast(concept_norm as {{ dbt.type_string() }})), '')     as concept_norm,
        nullif(trim(cast(concept_text as {{ dbt.type_string() }})), '')     as concept_text,
        nullif(trim(cast(canonical_name as {{ dbt.type_string() }})), '')   as canonical_name,
        lower(trim(cast(canonical_class as {{ dbt.type_string() }})))       as canonical_class,
        try_cast(canonicalized_at as timestamp)                              as canonicalized_at,
        nullif(trim(cast(model_version as {{ dbt.type_string() }})), '')    as model_version
    from source

),

numbered as (

    select
        *,
        row_number() over (
            partition by concept_class, concept_norm
            order by model_version desc, canonicalized_at desc
        ) as _rn
    from typed
    where concept_norm is not null and canonical_name is not null

)

select
    concept_class,
    concept_norm,
    concept_text,
    canonical_name,
    canonical_class,
    canonicalized_at,
    model_version
from numbered
where _rn = 1
