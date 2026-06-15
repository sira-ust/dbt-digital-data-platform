{% if not var('mysql_available') %}

-- No MySQL connection yet (POC phase) — return empty result with correct schema.
-- Downstream joins on this model will produce null category columns until
-- MySQL data is available. Set mysql_available: true in dbt_project.yml then.
-- Expand columns in the else branch once MySQL schema is confirmed.
select
    cast(null as bigint)    as category_id,
    cast(null as bigint)    as parent_id,
    cast(null as {{ dbt.type_string() }})   as category_name,
    cast(null as {{ dbt.type_string() }})   as parent_category_name,
    cast(null as integer)   as level,
    cast(null as boolean)   as is_active,
    cast(null as timestamp) as created_at,
    cast(null as timestamp) as updated_at
where false

{% else %}

with source as (

    select * from {{ source('mysql', 'category') }}

),

transformed as (

    select
        -- ── identifiers ────────────────────────────────────────────────
        cast(entity_id as bigint)                   as category_id,
        cast(nullif(trim(cast(parent_id as {{ dbt.type_string() }})), '') as bigint)
                                                    as parent_id,

        -- ── name ───────────────────────────────────────────────────────
        nullif(trim(name), '')                      as category_name,

        -- ── hierarchy ──────────────────────────────────────────────────
        cast(level as integer)                      as level,

        -- ── status ─────────────────────────────────────────────────────
        cast(is_active as boolean)                  as is_active,

        -- ── timestamps ─────────────────────────────────────────────────
        cast(nullif(trim(cast(created_at as {{ dbt.type_string() }})), '') as timestamp)
                                                    as created_at,
        cast(nullif(trim(cast(updated_at as {{ dbt.type_string() }})), '') as timestamp)
                                                    as updated_at

    from source

),

-- self-join to resolve parent name one level up
with_parent as (

    select
        c.category_id,
        c.parent_id,
        c.category_name,
        p.category_name                             as parent_category_name,
        c.level,
        c.is_active,
        c.created_at,
        c.updated_at
    from transformed as c
    left join transformed as p
        on c.parent_id = p.category_id

)

select * from with_parent

{% endif %}
