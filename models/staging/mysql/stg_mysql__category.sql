{% if not var('mysql_available') %}

select
    cast(null as bigint)                  as entity_id,
    cast(null as bigint)                  as parent_id,
    cast(null as {{ dbt.type_string() }}) as category_name,
    cast(null as bigint)                  as category_level,
    cast(null as {{ dbt.type_string() }}) as is_active,
    cast(null as timestamp)               as created_at,
    cast(null as timestamp)               as updated_at
where false

{% else %}

with source as (

    select * from {{ source('mysql', 'category') }}

)

select
    cast(entity_id as bigint)                                                        as entity_id,
    cast(nullif(trim(cast(parent_id   as {{ dbt.type_string() }})), '') as bigint)   as parent_id,
    nullif(trim(cast(name             as {{ dbt.type_string() }})), '')               as category_name,
    try_cast(nullif(trim(cast(level   as {{ dbt.type_string() }})), '') as bigint)    as category_level,
    nullif(trim(cast(is_active        as {{ dbt.type_string() }})), '')               as is_active,
    cast(nullif(trim(cast(created_at  as {{ dbt.type_string() }})), '') as timestamp) as created_at,
    cast(nullif(trim(cast(updated_at  as {{ dbt.type_string() }})), '') as timestamp) as updated_at
from source

{% endif %}
