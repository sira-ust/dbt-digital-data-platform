-- Download reliability — answers "what is the failure rate by download type
-- and platform, and how long do successful downloads take?"

{{
    config(
        materialized='incremental',
        unique_key='entity_id',
        on_schema_change='append_new_columns'
    )
}}

with downloads as (

    select * from {{ ref('int_downloads') }}

    {% if is_incremental() %}
    where entity_id > (select coalesce(max(entity_id), 0) from {{ this }})
    {% endif %}

)

select
    entity_id,
    cast(created_at_utc as date) as download_date_utc,
    created_at_utc,
    description_code,
    function_name,
    download_type_code,
    source_code,
    app_name,
    app_platform,
    app_version,
    device_name,
    is_success,
    is_failure,
    duration_s

from downloads
