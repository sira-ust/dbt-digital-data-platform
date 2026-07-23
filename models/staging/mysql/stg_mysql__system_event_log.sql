-- Lossless 1:1 staging for system_event_log. Light work only: cast, trim,
-- and dedupe (latest updated_at wins). Every source field is preserved with
-- its source name — NO decoding here. The 8-digit description_code split,
-- event_time→UTC conversion, location parse, and source decode all live in
-- int_events_decoded (see models/intermediate). When real MySQL lands (flat
-- table), drop the duckdb unnest branch.
--
-- The raw API response has a nested envelope:
--   { code, msg, data: { current_page, data: [ <events> ] } }
-- DuckDB (dev) reads that JSON directly and unnests data.data to one row per
-- event. Databricks (POC) reads the pre-flattened temp_system_events table
-- (one row per event already), so it skips the unnest. The raw_events CTE
-- normalises both to the same flat shape.

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

typed as (

    select
        cast(entity_id        as bigint)                     as entity_id,
        trim(cast(sales_code       as {{ dbt.type_string() }})) as sales_code,
        trim(cast(username         as {{ dbt.type_string() }})) as username,
        trim(cast(ust_customer_no  as {{ dbt.type_string() }})) as ust_customer_no,
        trim(cast(location         as {{ dbt.type_string() }})) as location,
        trim(cast(timezone         as {{ dbt.type_string() }})) as timezone,
        trim(cast(event_time       as {{ dbt.type_string() }})) as event_time,
        trim(cast(source           as {{ dbt.type_string() }})) as source,
        trim(cast(version          as {{ dbt.type_string() }})) as version,
        trim(cast(description_code as {{ dbt.type_string() }})) as description_code,
        cast(response         as {{ dbt.type_string() }})    as response,
        trim(cast(device_name      as {{ dbt.type_string() }})) as device_name,
        cast(created_at       as timestamp)                  as created_at,
        cast(updated_at       as timestamp)                  as updated_at,
        trim(cast(event_id         as {{ dbt.type_string() }})) as event_id
    from raw_events

),

numbered as (

    -- entity_id is the source primary key: keep the latest-updated row per id.
    -- updated_at desc is the documented rule ("latest wins"); created_at desc is
    -- a deterministic tiebreak. Partitioning by entity_id (not by the business
    -- columns) is what guarantees the unique(entity_id) test downstream.
    select
        *,
        row_number() over (
            partition by entity_id
            order by updated_at desc, created_at desc
        ) as _rn
    from typed

)

select
    entity_id,
    sales_code,
    username,
    ust_customer_no,
    location,
    timezone,
    event_time,
    source,
    version,
    description_code,
    response,
    device_name,
    created_at,
    updated_at,
    event_id
from numbered
where _rn = 1
