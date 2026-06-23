with source as (

    select * from {{ source('mysql', 'tracking_report') }}

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
    cast(entity_id as bigint)                                                          as entity_id,
    nullif(trim(cast(customer_id   as {{ dbt.type_string() }})), '')                   as customer_id,
    nullif(trim(cast(customer_name as {{ dbt.type_string() }})), '')                   as customer_name,
    nullif(trim(cast(session_id    as {{ dbt.type_string() }})), '')                   as session_id,
    nullif(trim(cast(model         as {{ dbt.type_string() }})), '')                   as device_model,
    nullif(trim(cast(version       as {{ dbt.type_string() }})), '')                   as app_version,
    try_cast(nullif(trim(cast(start_time as {{ dbt.type_string() }})), '') as timestamp) as start_time,
    try_cast(nullif(trim(cast(end_time    as {{ dbt.type_string() }})), '') as timestamp) as end_time,
    try_cast(nullif(trim(cast(total_event as {{ dbt.type_string() }})), '') as bigint)  as total_events,
    cast(create_at  as timestamp)                                                      as created_at,
    cast(updated_at as timestamp)                                                      as updated_at
from numbered
where _rn = 1
