-- Order submission health — answers "what is order volume and failure rate
-- by app source and entry point?" Event grain (one row per submission event)
-- so BI can aggregate freely; incremental on entity_id given ~600k events/mo.

{{
    config(
        materialized='incremental',
        unique_key='entity_id',
        on_schema_change='append_new_columns'
    )
}}

with orders as (

    select * from {{ ref('int_orders_submitted') }}

    {% if is_incremental() %}
    -- entity_id is an auto-increment PK: new events always have higher ids
    where entity_id > (select coalesce(max(entity_id), 0) from {{ this }})
    {% endif %}

)

select
    entity_id,
    cast(created_at_utc as date) as order_date_utc,
    created_at_utc,
    source_code,
    app_name,
    app_platform,
    order_source as entry_point,
    actor_type,
    customer_key,
    sales_code,
    increment_id,
    is_success,
    is_failure,
    grand_total,
    subtotal,
    total_item_count,
    duration_s as submission_duration_s

from orders
