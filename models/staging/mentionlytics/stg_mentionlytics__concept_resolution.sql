{{ config(tags=['social']) }}
-- Lossless staging for the concept->SKU resolution (produced by
-- scripts/resolve_trending_concepts.py). One row per concept_norm — the source
-- is append-only, so a re-resolution of the same concept is deduped here (latest
-- resolved_at wins). Cast + dedupe only; the recommended_* arrays pass through
-- unchanged. dbt never calls the LLM.
--
-- The v5 audit columns (recommended_reasons, rejected_*, name_mismatch_prtnums,
-- canonical_key, alias_of, proposer_confidence, snippet_count) are selected by
-- name, so the resolver has to have written at least one v5 row before this
-- model can build. That's the documented job order — resolve_trending_concepts
-- runs BEFORE `dbt build --select tag:social` — and the Delta write uses
-- mergeSchema, so the columns appear on the first v5 append. Locally the same
-- holds for data/mock/mentionlytics/concept_resolution.parquet.

with source as (

    select * from {{ source('mentionlytics', 'concept_resolution') }}

),

typed as (

    select
        nullif(trim(cast(concept_norm as {{ dbt.type_string() }})), '')     as concept_norm,
        nullif(trim(cast(canonical_label as {{ dbt.type_string() }})), '')  as canonical_label,
        nullif(trim(cast(group_primary as {{ dbt.type_string() }})), '')    as group_primary,
        nullif(trim(cast(group_label as {{ dbt.type_string() }})), '')      as group_label,
        nullif(trim(cast(concept_type as {{ dbt.type_string() }})), '')     as concept_type,
        nullif(trim(cast(result_type as {{ dbt.type_string() }})), '')      as result_type,
        nullif(trim(cast(matched_prtnum as {{ dbt.type_string() }})), '')   as matched_prtnum,
        recommended_prtnums,
        recommended_item_names,
        recommended_reasons,
        rejected_prtnums,
        rejected_reasons,
        name_mismatch_prtnums,
        cast(match_confidence as double)                                    as match_confidence,
        cast(proposer_confidence as double)                                 as proposer_confidence,
        cast(snippet_count as {{ dbt.type_int() }})                         as snippet_count,
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
    group_primary,
    group_label,
    concept_type,
    result_type,
    matched_prtnum,
    recommended_prtnums,
    recommended_item_names,
    recommended_reasons,
    rejected_prtnums,
    rejected_reasons,
    name_mismatch_prtnums,
    match_confidence,
    proposer_confidence,
    snippet_count,
    resolved_at,
    model_version
from numbered
where _rn = 1
