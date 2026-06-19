{% if target.type == 'duckdb' %}

-- No local JSON sample for admin_users; emit an empty schema-correct result.
-- On Databricks this reads the real ust_databricks.mysql.admin_users table.
select
    cast(null as bigint)                  as user_id,
    cast(null as {{ dbt.type_string() }}) as username,
    cast(null as {{ dbt.type_string() }}) as first_name,
    cast(null as {{ dbt.type_string() }}) as last_name,
    cast(null as {{ dbt.type_string() }}) as email,
    cast(null as {{ dbt.type_string() }}) as salesperson_code,
    cast(null as {{ dbt.type_string() }}) as role_name,
    cast(null as {{ dbt.type_string() }}) as interface_locale,
    cast(null as bigint)                  as is_active,
    cast(null as bigint)                  as is_salesperson,
    cast(null as bigint)                  as convert_quotes,
    cast(null as bigint)                  as receive_quote_emails,
    cast(null as bigint)                  as lognum,
    cast(null as timestamp)               as logdate,
    cast(null as timestamp)               as created_at,
    cast(null as timestamp)               as updated_at
where false

{% else %}

with source as (

    select * from {{ source('mysql', 'admin_users') }}

)

select
    cast(user_id as bigint)                                                                as user_id,
    nullif(trim(cast(username             as {{ dbt.type_string() }})), '')                as username,
    nullif(trim(cast(firstname            as {{ dbt.type_string() }})), '')                as first_name,
    nullif(trim(cast(lastname             as {{ dbt.type_string() }})), '')                as last_name,
    nullif(trim(cast(email                as {{ dbt.type_string() }})), '')                as email,
    nullif(trim(cast(salesperson_code     as {{ dbt.type_string() }})), '')                as salesperson_code,
    nullif(trim(cast(role_name            as {{ dbt.type_string() }})), '')                as role_name,
    nullif(trim(cast(interface_locale     as {{ dbt.type_string() }})), '')                as interface_locale,
    try_cast(nullif(trim(cast(is_active            as {{ dbt.type_string() }})), '') as bigint) as is_active,
    try_cast(nullif(trim(cast(is_salesperson       as {{ dbt.type_string() }})), '') as bigint) as is_salesperson,
    try_cast(nullif(trim(cast(convert_quotes       as {{ dbt.type_string() }})), '') as bigint) as convert_quotes,
    try_cast(nullif(trim(cast(receive_quote_emails as {{ dbt.type_string() }})), '') as bigint) as receive_quote_emails,
    try_cast(nullif(trim(cast(lognum               as {{ dbt.type_string() }})), '') as bigint) as lognum,
    cast(nullif(trim(cast(logdate         as {{ dbt.type_string() }})), '') as timestamp)   as logdate,
    cast(nullif(trim(cast(created         as {{ dbt.type_string() }})), '') as timestamp)   as created_at,
    cast(nullif(trim(cast(modified        as {{ dbt.type_string() }})), '') as timestamp)   as updated_at
from source

{% endif %}
