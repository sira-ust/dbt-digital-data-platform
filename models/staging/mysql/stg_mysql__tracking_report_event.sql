with source as (

    select * from {{ source('mysql', 'tracking_report_event') }}

),

numbered as (

    select
        *,
        row_number() over (
            partition by entity_id
            order by updated_at desc
        ) as _rn
    from source

)

select
    cast(entity_id as bigint)                                                            as entity_id,
    cast(parent_id as bigint)                                                            as tracking_report_id,
    nullif(trim(cast(customer_id     as {{ dbt.type_string() }})), '')                   as customer_id,
    nullif(trim(cast(customer_name   as {{ dbt.type_string() }})), '')                   as customer_name,
    nullif(trim(cast(type            as {{ dbt.type_string() }})), '')                   as event_type_code,
    nullif(trim(cast(title           as {{ dbt.type_string() }})), '')                   as title,
    cast(start_time as timestamp)                                                        as start_time,
    try_cast(nullif(trim(cast(end_time as {{ dbt.type_string() }})), '') as timestamp)   as end_time,
    nullif(trim(cast(item_no         as {{ dbt.type_string() }})), '')                   as item_no,
    nullif(trim(cast(sku             as {{ dbt.type_string() }})), '')                   as sku,
    nullif(trim(cast(qty             as {{ dbt.type_string() }})), '')                   as qty,
    nullif(trim(cast(quote_id        as {{ dbt.type_string() }})), '')                   as quote_id,
    nullif(trim(cast(keyword         as {{ dbt.type_string() }})), '')                   as keyword,
    nullif(trim(cast(page            as {{ dbt.type_string() }})), '')                   as page,
    nullif(trim(cast(event_type      as {{ dbt.type_string() }})), '')                   as event_type,
    nullif(trim(cast(notes           as {{ dbt.type_string() }})), '')                   as notes,
    nullif(trim(cast(address         as {{ dbt.type_string() }})), '')                   as address,
    nullif(trim(cast(source          as {{ dbt.type_string() }})), '')                   as source,
    try_cast(nullif(trim(cast(second as {{ dbt.type_string() }})), '') as bigint)        as duration_seconds,
    nullif(trim(cast(method          as {{ dbt.type_string() }})), '')                   as method,
    nullif(trim(cast(categories_name as {{ dbt.type_string() }})), '')                   as categories_name,
    nullif(trim(cast(icon            as {{ dbt.type_string() }})), '')                   as icon,
    nullif(trim(cast(timezone        as {{ dbt.type_string() }})), '')                   as timezone,
    nullif(trim(cast(version         as {{ dbt.type_string() }})), '')                   as app_version,
    cast(create_at  as timestamp)                                                        as created_at,
    cast(updated_at as timestamp)                                                        as updated_at
from numbered
where _rn = 1
