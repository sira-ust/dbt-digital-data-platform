{% if target.type == 'duckdb' %}

-- No local JSON sample for category; emit an empty schema-correct result.
-- On Databricks this reads the real ust_databricks.mysql.category table.
select
    cast(null as bigint)                  as entity_id,
    cast(null as bigint)                  as parent_id,
    cast(null as {{ dbt.type_string() }}) as category_name,
    cast(null as {{ dbt.type_string() }}) as is_active,
    cast(null as bigint)                  as position,
    cast(null as bigint)                  as category_level,
    cast(null as bigint)                  as product_count,
    cast(null as {{ dbt.type_string() }}) as meta_title,
    cast(null as {{ dbt.type_string() }}) as meta_keywords,
    cast(null as {{ dbt.type_string() }}) as meta_description,
    cast(null as timestamp)               as created_at,
    cast(null as timestamp)               as updated_at
where false

{% else %}

with source as (

    select * from {{ source('mysql', 'category') }}

)

select
    cast(category_id as bigint)                                                        as entity_id,
    cast(nullif(trim(cast(parent_id     as {{ dbt.type_string() }})), '') as bigint)   as parent_id,
    nullif(trim(cast(name               as {{ dbt.type_string() }})), '')              as category_name,
    nullif(trim(cast(is_active          as {{ dbt.type_string() }})), '')              as is_active,
    try_cast(nullif(trim(cast(position      as {{ dbt.type_string() }})), '') as bigint) as position,
    try_cast(nullif(trim(cast(level         as {{ dbt.type_string() }})), '') as bigint) as category_level,
    try_cast(nullif(trim(cast(product_count as {{ dbt.type_string() }})), '') as bigint) as product_count,
    nullif(trim(cast(meta_title         as {{ dbt.type_string() }})), '')              as meta_title,
    nullif(trim(cast(meta_keywords      as {{ dbt.type_string() }})), '')              as meta_keywords,
    nullif(trim(cast(meta_description   as {{ dbt.type_string() }})), '')              as meta_description,
    cast(nullif(trim(cast(create_at     as {{ dbt.type_string() }})), '') as timestamp) as created_at,
    cast(nullif(trim(cast(updated_at    as {{ dbt.type_string() }})), '') as timestamp) as updated_at
from source

{% endif %}
