-- The raw API response has a nested envelope:
--   { code, msg, data: { current_page, data: [ <events> ] } }
-- DuckDB (dev) reads that JSON directly and unnests data.data to one row per
-- event. Databricks (POC) reads the pre-flattened temp_system_events table
-- (one row per event already), so it skips the unnest. The raw_events CTE
-- normalises both to the same flat shape; everything below is shared.
-- When real MySQL lands (flat table), drop the duckdb branch.

{% if target.type == 'duckdb' %}

with exploded as (

    -- unnest the events array from the nested API envelope data.data
    select unnest(data.data) as evt
    from {{ source('mysql', 'system_event_log') }}

),

raw_events as (

    select
        evt.entity_id,        evt.sales_code,      evt.username,
        evt.ust_customer_no,  evt.location,        evt.timezone,
        evt.event_time,       evt.source,          evt.version,
        evt.description_code, evt.response,        evt.device_name,
        evt.created_at,       evt.updated_at,      evt.event_id
    from exploded

),

{% else %}

with raw_events as (

    -- Databricks: temp_system_events is already one row per event
    select
        entity_id,        sales_code,      username,
        ust_customer_no,  location,        timezone,
        event_time,       source,          version,
        description_code, response,        device_name,
        created_at,       updated_at,      event_id
    from {{ source('mysql', 'system_event_log') }}

),

{% endif %}

source as (

    select
        cast(entity_id        as bigint)                     as entity_id,
        cast(sales_code       as {{ dbt.type_string() }})    as sales_code,
        cast(username         as {{ dbt.type_string() }})    as username,
        cast(ust_customer_no  as {{ dbt.type_string() }})    as ust_customer_no,
        cast(location         as {{ dbt.type_string() }})    as location,
        cast(timezone         as {{ dbt.type_string() }})    as timezone,
        cast(event_time       as timestamp)                  as event_time,
        cast(source           as {{ dbt.type_string() }})    as source,
        cast(version          as {{ dbt.type_string() }})    as version,
        cast(description_code as {{ dbt.type_string() }})    as description_code,
        cast(response         as {{ dbt.type_string() }})    as response,
        cast(device_name      as {{ dbt.type_string() }})    as device_name,
        cast(created_at       as timestamp)                  as created_at,
        cast(updated_at       as timestamp)                  as updated_at,
        cast(event_id         as {{ dbt.type_string() }})    as event_id
    from raw_events

),

numbered as (

    select
        *,
        row_number() over (
            partition by entity_id
            order by updated_at desc
        ) as _rn
    from source

),

deduped as (

    select * from numbered where _rn = 1

),

transformed as (

    select
        -- ── identifiers ────────────────────────────────────────────────
        cast(entity_id as bigint)                                           as entity_id,
        nullif(trim(sales_code), '')                                        as sales_code,
        nullif(trim(username), '')                                          as username,
        nullif(trim(ust_customer_no), '')                                   as ust_customer_no,
        nullif(trim(device_name), '')                                       as device_name,
        cast(source as {{ dbt.type_string() }})                            as source_code,
        nullif(trim(version), '')                                           as app_version,

        -- ── event code: 8-digit hierarchical split ─────────────────────
        cast(description_code as {{ dbt.type_string() }})                  as description_code,
        substr(cast(description_code as {{ dbt.type_string() }}), 1, 2)    as l1_code,
        substr(cast(description_code as {{ dbt.type_string() }}), 3, 2)    as l2_code,
        substr(cast(description_code as {{ dbt.type_string() }}), 5, 2)    as l3_code,
        substr(cast(description_code as {{ dbt.type_string() }}), 7, 2)    as l4_code,
        substr(cast(description_code as {{ dbt.type_string() }}), 7, 2) = '01' as is_success,
        substr(cast(description_code as {{ dbt.type_string() }}), 7, 2) = '02' as is_failure,

        -- ── timestamps ─────────────────────────────────────────────────
        {{ add_hours(
            'cast(event_time as timestamp)',
            '-coalesce(' ~ tz_offset_hours('timezone') ~ ', 0)'
        ) }}                                                                as event_at_utc,
        cast(timezone as {{ dbt.type_string() }})                          as device_timezone,
        {{ add_hours('cast(created_at as timestamp)', 8) }}                as created_at_utc,
        {{ add_hours('cast(updated_at as timestamp)', 8) }}                as updated_at_utc,
        {{ epoch_millis_to_ts('event_id') }}                               as event_id_at_utc,

        -- ── geo: "lat,lon" or empty ─────────────────────────────────────
        try_cast({{ response_part('location', 1) }} as double)              as latitude,
        try_cast({{ response_part('location', 2) }} as double)              as longitude,

        -- ── actor ──────────────────────────────────────────────────────
        case
            when source in ('PDA-A', 'CatalogFS-I', 'CatalogFS-A') then 'sales'
            else 'customer'
        end                                                                 as actor_type,
        case
            when source in ('PDA-A', 'CatalogFS-I', 'CatalogFS-A')
                then nullif(trim(ust_customer_no), '')
            else nullif(trim(username), '')
        end                                                                 as customer_key,

        -- ── payload ─────────────────────────────────────────────────────
        cast(response as {{ dbt.type_string() }})                          as response

    from deduped

)

select * from transformed
