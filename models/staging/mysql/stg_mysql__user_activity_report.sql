with source as (

    select * from {{ source('mysql', 'user_activity_report') }}

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
    cast(entity_id as bigint)                                                             as entity_id,
    nullif(trim(cast(user             as {{ dbt.type_string() }})), '')                    as username,
    nullif(trim(cast(user_name        as {{ dbt.type_string() }})), '')                    as user_name,
    nullif(trim(cast(session_id       as {{ dbt.type_string() }})), '')                    as session_id,
    cast(begin_time as timestamp)                                                          as begin_time,
    try_cast(nullif(trim(cast(end_time        as {{ dbt.type_string() }})), '') as timestamp) as end_time,
    try_cast(nullif(trim(cast(event_count     as {{ dbt.type_string() }})), '') as bigint) as event_count,
    try_cast(nullif(trim(cast(voluntarily_exit as {{ dbt.type_string() }})), '') as bigint) as voluntarily_exit,
    nullif(trim(cast(model            as {{ dbt.type_string() }})), '')                    as device_model,
    nullif(trim(cast(location         as {{ dbt.type_string() }})), '')                    as location,
    nullif(trim(cast(sales_name       as {{ dbt.type_string() }})), '')                    as sales_name,
    nullif(trim(cast(version          as {{ dbt.type_string() }})), '')                    as app_version,
    cast(created_at as timestamp)                                                          as created_at,
    cast(updated_at as timestamp)                                                          as updated_at
from numbered
where _rn = 1
