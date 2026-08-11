{{ config(tags=['social']) }}
-- Lossless staging for the concept->SKU resolution (produced by
-- scripts/resolve_trending_concepts.py). One row per concept_norm — the source
-- is append-only, so a re-resolution of the same concept is deduped here (latest
-- resolved_at wins). Cast + dedupe only; the recommended_* arrays pass through
-- unchanged. dbt never calls the LLM.

with source as (

    select * from {{ source('mentionlytics', 'concept_resolution') }}

),

typed as (

    select
        nullif(trim(cast(concept_norm as {{ dbt.type_string() }})), '')     as concept_norm,
        nullif(trim(cast(canonical_label as {{ dbt.type_string() }})), '')  as canonical_label,
        nullif(trim(cast(concept_type as {{ dbt.type_string() }})), '')     as concept_type,
        nullif(trim(cast(result_type as {{ dbt.type_string() }})), '')      as result_type,
        nullif(trim(cast(matched_prtnum as {{ dbt.type_string() }})), '')   as matched_prtnum,
        recommended_prtnums,
        recommended_item_names,
        cast(match_confidence as double)                                    as match_confidence,
        cast(resolved_at as timestamp)                                      as resolved_at,
        nullif(trim(cast(model_version as {{ dbt.type_string() }})), '')    as model_version
    from source

),

numbered as (

    select *,
        row_number() over (partition by concept_norm order by resolved_at desc) as _rn
    from typed

)

select
    concept_norm,
    canonical_label,
    concept_type,
    result_type,
    matched_prtnum,
    recommended_prtnums,
    recommended_item_names,
    match_confidence,
    resolved_at,
    model_version
from numbered
where _rn = 1
