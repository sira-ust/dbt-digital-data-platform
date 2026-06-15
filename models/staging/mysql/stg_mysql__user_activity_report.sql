with source as (

    select * from {{ source('mysql', 'user_activity_report') }}

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
        nullif(trim(user), '')                                              as username,
        nullif(trim(user_name), '')                                         as display_name,
        nullif(trim(session_id), '')                                        as session_id,

        -- ── device ─────────────────────────────────────────────────────
        nullif(trim(model), '')                                             as device_model,
        nullif(trim(version), '')                                           as app_version,
        try_cast(nullif(split_part(version, '.', 1), '') as integer)        as version_major,
        try_cast(nullif(split_part(version, '.', 2), '') as integer)        as version_minor,
        -- build segment may have suffix ("18b178 - PDA") — extract leading digits only
        try_cast(
            nullif(regexp_extract(split_part(version, '.', 3), '^([0-9]+)', 1), '')
            as integer
        )                                                                   as version_build,

        -- ── timestamps (no timezone at session level) ───────────────────
        cast(begin_time as timestamp)                                       as started_at,
        try_cast(end_time as timestamp)                                     as ended_at,

        -- ── geo: "lat,lon" or null ──────────────────────────────────────
        try_cast({{ response_part('location', 1) }} as double)              as latitude,
        try_cast({{ response_part('location', 2) }} as double)              as longitude,

        -- ── additional session context ─────────────────────────────────
        nullif(trim(sales_name), '')                                        as sales_name,

        -- ── flags ──────────────────────────────────────────────────────
        cast(voluntarily_exit as boolean)                                   as is_voluntary_exit,

        -- ── metrics ────────────────────────────────────────────────────
        cast(event_count as integer)                                        as event_count,

        -- ── server timestamps ───────────────────────────────────────────
        cast(created_at as timestamp)                                       as created_at_server,
        cast(updated_at as timestamp)                                       as updated_at_server

    from deduped
    where _rn = 1

)

select * from transformed
