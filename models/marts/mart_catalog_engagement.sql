-- Catalog engagement — answers "how much time do users spend per catalog
-- category?" (19010000 Catalog View events, kv payload).

{{
    config(
        materialized='incremental',
        unique_key='entity_id',
        on_schema_change='append_new_columns'
    )
}}

with views as (

    select * from {{ ref('int_catalog_views') }}

    {% if is_incremental() %}
    where entity_id > (select coalesce(max(entity_id), 0) from {{ this }})
    {% endif %}

)

select
    entity_id,
    cast(created_at_utc as date) as view_date_utc,
    created_at_utc,
    source_code,
    app_name,
    app_platform,
    actor_type,
    customer_key,
    sales_code,
    category_id,
    category_name,
    visits_num,
    time_s

from views
