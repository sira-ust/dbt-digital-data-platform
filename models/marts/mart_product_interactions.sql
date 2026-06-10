-- Placeholder — product interactions (adds/removes/qty changes/detail views
-- by sku and page context). Scaffolded thin; refine event-family mapping
-- (which 14/15 codes mean add vs remove vs qty change) from the full
-- Section-5 dictionary once pasted into seed_event_codes.

{{
    config(
        materialized='incremental',
        unique_key='entity_id',
        on_schema_change='append_new_columns'
    )
}}

with interactions as (

    select * from {{ ref('int_item_interactions') }}

    {% if is_incremental() %}
    where entity_id > (select coalesce(max(entity_id), 0) from {{ this }})
    {% endif %}

)

select
    entity_id,
    cast(created_at_utc as date) as interaction_date_utc,
    created_at_utc,
    description_code,
    function_name,
    l1_code,
    source_code,
    app_name,
    app_platform,
    actor_type,
    customer_key,
    sku,
    page_context,
    clicked_title,
    scan_category_id

from interactions
