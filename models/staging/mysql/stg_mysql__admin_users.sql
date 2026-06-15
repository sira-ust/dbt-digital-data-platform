{% if not var('mysql_available') %}

-- No MySQL connection yet (POC phase) — return empty result with correct schema.
-- Downstream LEFT JOINs on this model will produce null for all user columns,
-- which is the correct behaviour before admin_users data is available.
-- Set mysql_available: true in dbt_project.yml when MySQL credentials are live.
select
    cast(null as bigint)    as user_id,
    cast(null as {{ dbt.type_string() }})   as username,
    cast(null as {{ dbt.type_string() }})   as salesperson_code,
    cast(null as {{ dbt.type_string() }})   as firstname,
    cast(null as {{ dbt.type_string() }})   as lastname,
    cast(null as {{ dbt.type_string() }})   as full_name,
    cast(null as {{ dbt.type_string() }})   as role_name,
    cast(null as boolean)   as is_active
where false

{% else %}

with source as (

    select * from {{ source('mysql', 'admin_users') }}

),

transformed as (

    select
        -- ── identifiers ────────────────────────────────────────────────
        cast(user_id as bigint)                                             as user_id,
        nullif(trim(username), '')                                          as username,
        nullif(trim(salesperson_code), '')                                  as salesperson_code,

        -- ── name ───────────────────────────────────────────────────────
        nullif(trim(firstname), '')                                         as firstname,
        nullif(trim(lastname), '')                                          as lastname,
        nullif(trim(firstname), '') || ' ' || nullif(trim(lastname), '')    as full_name,

        -- ── role & status ───────────────────────────────────────────────
        nullif(trim(role_name), '')                                         as role_name,
        cast(is_active as boolean)                                          as is_active

    from source

)

select * from transformed

{% endif %}
