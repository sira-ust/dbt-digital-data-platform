{% if not var('mysql_available') %}

select
    cast(null as bigint)                  as user_id,
    cast(null as {{ dbt.type_string() }}) as username,
    cast(null as {{ dbt.type_string() }}) as first_name,
    cast(null as {{ dbt.type_string() }}) as last_name,
    cast(null as {{ dbt.type_string() }}) as salesperson_code,
    cast(null as {{ dbt.type_string() }}) as role_name,
    cast(null as {{ dbt.type_string() }}) as is_active
where false

{% else %}

with source as (

    select * from {{ source('mysql', 'admin_users') }}

)

select
    cast(user_id as bigint)                                              as user_id,
    nullif(trim(cast(username         as {{ dbt.type_string() }})), '')  as username,
    nullif(trim(cast(firstname        as {{ dbt.type_string() }})), '')  as first_name,
    nullif(trim(cast(lastname         as {{ dbt.type_string() }})), '')  as last_name,
    nullif(trim(cast(salesperson_code as {{ dbt.type_string() }})), '')  as salesperson_code,
    nullif(trim(cast(role_name        as {{ dbt.type_string() }})), '')  as role_name,
    nullif(trim(cast(is_active        as {{ dbt.type_string() }})), '')  as is_active
from source

{% endif %}
