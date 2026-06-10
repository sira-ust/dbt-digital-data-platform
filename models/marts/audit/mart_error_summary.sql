-- mart_error_summary — triage rollup of mart_event_record_errors.
--
-- One row per (error_type, description_code): how big is the problem, since
-- when, on which apps, and sample payloads to aid diagnosis. Contains NO
-- detection logic of its own — mart_event_record_errors is the single
-- source of truth for what counts as an error; this is just a readable lens
-- over it (at production volume the row-level table is too big to eyeball).
--
-- For unknown_event_code rows, suspected_l1_category infers the family from
-- documented sibling codes sharing the same 2-digit L1 prefix.
--
-- Triage: confirm unknowns with the API team; once a code/source/category
-- is added to the official seed (and the glossary regenerated via
-- scripts/generate_event_glossary.py), its rows clear on the next build.

{{ config(materialized='view') }}

with errors as (

    select * from {{ ref('mart_event_record_errors') }}

),

-- L1 prefix -> category name, inferred from documented sibling codes
l1_names as (

    select
        substr(description_code, 1, 2) as l1_code,
        min(l1_category_name) as l1_category_name
    from {{ ref('seed_event_codes') }}
    group by substr(description_code, 1, 2)

),

aggregated as (

    select
        error_type,
        severity,
        description_code,
        count(*) as violation_count,
        count(distinct source_code) as distinct_sources,
        min(source_code) as sample_source,
        min(created_at_utc) as first_seen_utc,
        max(created_at_utc) as last_seen_utc,
        max(entity_id) as last_entity_id,
        min(error_detail) as sample_error_detail,
        sum(case when response is not null and trim(response) <> '' then 1 else 0 end)
            as records_with_payload,
        min(response) as sample_response_min,
        max(response) as sample_response_max
    from errors
    group by error_type, severity, description_code

)

select
    a.error_type,
    a.severity,
    a.description_code,
    coalesce(l1.l1_category_name, 'UNKNOWN L1 FAMILY') as suspected_l1_category,
    a.violation_count,
    a.distinct_sources,
    a.sample_source,
    a.first_seen_utc,
    a.last_seen_utc,
    a.last_entity_id,
    a.sample_error_detail,
    a.records_with_payload,
    a.sample_response_min,
    a.sample_response_max
from aggregated a
left join l1_names l1
    on substr(a.description_code, 1, 2) = l1.l1_code
order by a.error_type, a.violation_count desc
