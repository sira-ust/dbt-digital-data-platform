with source as (

    select * from {{ source('mysql', 'tracking_report_event') }}

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
        cast(parent_id as bigint)                                           as session_entity_id,
        nullif(trim(customer_id), '')                                       as customer_id,
        nullif(trim(customer_name), '')                                     as customer_name,

        -- ── event classification ────────────────────────────────────────
        cast(type as integer)                                               as event_type_code,
        nullif(trim(title), '')                                             as title,
        nullif(trim(page), '')                                              as page,
        nullif(trim(event_type), '')                                        as event_type_label,
        cast(method as integer)                                             as method_code,

        -- ── timestamps ─────────────────────────────────────────────────
        cast(start_time as timestamp)                                       as started_at,
        try_cast(nullif(trim(cast(end_time as {{ dbt.type_string() }})), '') as timestamp)  as ended_at,
        cast(timezone as {{ dbt.type_string() }})                          as device_timezone,
        -- duration stored as string in source ("1.0", "20.0")
        try_cast(second as double)                                          as duration_seconds,

        -- ── product context ─────────────────────────────────────────────
        nullif(trim(item_no), '')                                           as item_no,
        nullif(trim(sku), '')                                               as sku,
        cast(qty as integer)                                                as qty,
        nullif(trim(quote_id), '')                                          as quote_id,
        nullif(trim(categories_name), '')                                   as categories_name,
        nullif(trim(keyword), '')                                           as keyword,

        -- ── additional context ──────────────────────────────────────────
        nullif(trim(notes), '')                                             as notes,
        nullif(trim(address), '')                                           as address,
        nullif(trim(source), '')                                            as source,
        nullif(trim(icon), '')                                              as icon,
        nullif(trim(version), '')                                           as app_version,

        -- ── server timestamps (source field is 'create_at' — DB typo) ──
        cast(create_at as timestamp)                                        as created_at_server,
        cast(updated_at as timestamp)                                       as updated_at_server

    from deduped
    where _rn = 1

)

select * from transformed
