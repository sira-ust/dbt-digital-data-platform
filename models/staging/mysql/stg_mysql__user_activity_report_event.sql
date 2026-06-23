with source as (

    select * from {{ source('mysql', 'user_activity_report_event') }}

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
    cast(report_entity_id as bigint)                                                      as user_activity_report_id,
    nullif(trim(cast(user        as {{ dbt.type_string() }})), '')                         as username,
    nullif(trim(cast(act_type    as {{ dbt.type_string() }})), '')                         as activity_type,
    try_cast(nullif(trim(cast(begin_time as {{ dbt.type_string() }})), '') as timestamp)   as begin_time,
    try_cast(nullif(trim(cast(end_time   as {{ dbt.type_string() }})), '') as timestamp)   as end_time,
    nullif(trim(cast(customer     as {{ dbt.type_string() }})), '')                        as customer,
    nullif(trim(cast(keyword      as {{ dbt.type_string() }})), '')                        as keyword,
    nullif(trim(cast(location     as {{ dbt.type_string() }})), '')                        as location,
{%- if target.type == 'duckdb' %}
    -- local JSON sample has no `layout` column; real MySQL does
    cast(null as {{ dbt.type_string() }})                                                  as layout,
{%- else %}
    nullif(trim(cast(layout       as {{ dbt.type_string() }})), '')                        as layout,
{%- endif %}
    nullif(trim(cast(category     as {{ dbt.type_string() }})), '')                        as category,
    try_cast(nullif(trim(cast(visits_num as {{ dbt.type_string() }})), '') as bigint)      as visits_num,
    nullif(trim(cast(sku          as {{ dbt.type_string() }})), '')                        as sku,
    nullif(trim(cast(title        as {{ dbt.type_string() }})), '')                        as title,
    try_cast(nullif(trim(cast(is_wifi    as {{ dbt.type_string() }})), '') as bigint)      as is_wifi,
    try_cast(nullif(trim(cast(is_done    as {{ dbt.type_string() }})), '') as bigint)      as is_done,
    nullif(trim(cast(device_space as {{ dbt.type_string() }})), '')                        as device_space,
    nullif(trim(cast(response     as {{ dbt.type_string() }})), '')                        as response,
    try_cast(nullif(trim(cast(battery    as {{ dbt.type_string() }})), '') as bigint)      as battery,
    nullif(trim(cast(timezone     as {{ dbt.type_string() }})), '')                        as timezone,
    try_cast(nullif(trim(cast(is_login   as {{ dbt.type_string() }})), '') as bigint)      as is_login,
    nullif(trim(cast(method       as {{ dbt.type_string() }})), '')                        as method,
    nullif(trim(cast(qty          as {{ dbt.type_string() }})), '')                        as qty,
    cast(updated_at as timestamp)                                                          as updated_at
from numbered
where _rn = 1
