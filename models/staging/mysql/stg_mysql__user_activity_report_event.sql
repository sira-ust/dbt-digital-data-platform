with source as (

    select * from {{ source('mysql', 'user_activity_report_event') }}

),

deduped as (

    select
        *,
        row_number() over (
            partition by entity_id
            order by updated_at desc
        ) as _rn
    from source

),

transformed as (

    select
        -- ── identifiers ────────────────────────────────────────────────
        cast(entity_id as bigint)                                           as entity_id,
        cast(report_entity_id as bigint)                                    as session_entity_id,
        nullif(trim(user), '')                                              as username,
        nullif(trim(user_name), '')                                         as display_name,
        nullif(trim(sales_code), '')                                        as sales_code,

        -- ── event classification ────────────────────────────────────────
        cast(act_type as integer)                                           as activity_type_code,
        nullif(trim(title), '')                                             as title,

        -- ── timestamps ─────────────────────────────────────────────────
        cast(begin_time as timestamp)                                       as started_at,
        -- end_time can be an empty string ("") in the source
        try_cast(nullif(trim(cast(end_time as {{ dbt.type_string() }})), '') as timestamp)  as ended_at,
        cast(timezone as {{ dbt.type_string() }})                          as device_timezone,

        -- ── geo: "lat,lon" or empty ─────────────────────────────────────
        try_cast({{ response_part('location', 1) }} as double)              as latitude,
        try_cast({{ response_part('location', 2) }} as double)              as longitude,

        -- ── customer context ────────────────────────────────────────────
        nullif(trim(customer), '')                                          as customer_id,
        nullif(trim(keyword), '')                                           as keyword,
        nullif(trim(category), '')                                          as category,
        nullif(trim(sku), '')                                               as sku,
        cast(qty as integer)                                                as qty,
        nullif(trim(visits_num), '')                                        as visits_num,

        -- ── device state ────────────────────────────────────────────────
        cast(is_wifi as boolean)                                            as is_wifi,
        cast(battery as integer)                                            as battery_pct,
        nullif(trim(device_space), '')                                      as device_space,
        nullif(trim(version), '')                                           as app_version,

        -- ── flags ──────────────────────────────────────────────────────
        cast(is_done as boolean)                                            as is_done,
        -- is_login is a string "1" or empty in source, not a native boolean
        coalesce(nullif(trim(is_login), '') = '1', false)                  as is_login,

        -- ── payload ─────────────────────────────────────────────────────
        nullif(trim(response), '')                                          as response,
        cast(method as integer)                                             as method_code,

        -- ── server timestamps ───────────────────────────────────────────
        cast(updated_at as timestamp)                                       as updated_at_server

    from deduped
    where _rn = 1

)

select * from transformed
