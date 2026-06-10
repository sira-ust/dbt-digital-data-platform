-- Placeholder — login activity (volume, success/failure, by app and user
-- type). Scaffolded thin; extend with sessionization / distinct-user rollups
-- once dashboard requirements land.

{{
    config(
        materialized='incremental',
        unique_key='entity_id',
        on_schema_change='append_new_columns'
    )
}}

with logins as (

    select * from {{ ref('int_logins') }}

    {% if is_incremental() %}
    where entity_id > (select coalesce(max(entity_id), 0) from {{ this }})
    {% endif %}

)

select
    entity_id,
    cast(created_at_utc as date) as login_date_utc,
    created_at_utc,
    source_code,
    app_name,
    app_platform,
    actor_type,
    username,
    customer_key,
    is_success,
    is_failure

from logins
