-- stg_mysql__system_events — typed, deduped view over the System Event Log.
--
-- Responsibilities:
--   * Dedup on entity_id (auto-increment PK; keep latest updated_at)
--   * Split description_code into L1-L4 + success/failure flags
--   * Two-timezone handling:
--       event_time   device LOCAL time  -> UTC via per-row GMT offset
--       created_at   server FIXED PST   -> UTC via constant +8h (no DST rules)
--   * event_id (epoch millis) -> event_id_at_utc (nullable device timestamp)
--   * location "lat,lon" -> latitude / longitude
--   * actor_type + unified customer key from the username/ust_customer_no rules
--   * version -> major / minor / build
--
-- NOT here: payload (`response`) parsing — formats vary per event family, so
-- that lives in the per-family intermediate models.
--
-- NOTE: do NOT assume event_at_utc <= created_at_utc — device clock drift and
-- offline queueing make ordering unreliable. Order/dedup on entity_id only.

with source as (

    select * from {{ source('mysql', 'system_events') }}

),

numbered as (

    -- dedup on entity_id, keep latest updated_at (portable; no QUALIFY — Fabric)
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
        cast(entity_id as bigint) as entity_id,
        nullif(trim(sales_code), '') as sales_code,
        nullif(trim(username), '') as username,
        nullif(trim(ust_customer_no), '') as ust_customer_no,
        nullif(trim(device_name), '') as device_name,
        cast(source as varchar) as source_code,

        -- ── event code: 8-digit hierarchical split ─────────────────────
        cast(description_code as varchar) as description_code,
        substr(cast(description_code as varchar), 1, 2) as l1_code,
        substr(cast(description_code as varchar), 3, 2) as l2_code,
        substr(cast(description_code as varchar), 5, 2) as l3_code,
        substr(cast(description_code as varchar), 7, 2) as l4_code,
        substr(cast(description_code as varchar), 7, 2) = '01' as is_success,
        substr(cast(description_code as varchar), 7, 2) = '02' as is_failure,

        -- ── timestamps ─────────────────────────────────────────────────
        -- device local -> UTC: subtract the device offset (GMT+8 -> -8h)
        {{ add_hours(
            'cast(event_time as timestamp)',
            '-coalesce(' ~ tz_offset_hours('timezone') ~ ', 0)'
        ) }} as event_at_utc,
        cast(timezone as varchar) as device_timezone,

        -- server fixed PST (UTC-8, no DST) -> UTC: constant +8h
        {{ add_hours('cast(created_at as timestamp)', 8) }} as created_at_utc,
        {{ add_hours('cast(updated_at as timestamp)', 8) }} as updated_at_utc,

        -- device-side epoch-millis timestamp (nullable; treat as advisory)
        {{ epoch_millis_to_ts('event_id') }} as event_id_at_utc,

        -- ── geo: "lat,lon" or empty ─────────────────────────────────────
        try_cast({{ response_part('location', 1) }} as double) as latitude,
        try_cast({{ response_part('location', 2) }} as double) as longitude,

        -- ── actor: sales apps vs customer apps ──────────────────────────
        case
            when source in ('PDA-A', 'CatalogFS-I', 'CatalogFS-A') then 'sales'
            else 'customer'
        end as actor_type,
        -- unified customer key: salesperson acts FOR ust_customer_no;
        -- on customer apps the username IS the customer account no.
        case
            when source in ('PDA-A', 'CatalogFS-I', 'CatalogFS-A')
                then nullif(trim(ust_customer_no), '')
            else nullif(trim(username), '')
        end as customer_key,

        -- ── app version: major.minor.build ─────────────────────────────
        -- split_part shares the same signature on DuckDB and Databricks
        cast(version as varchar) as app_version,
        try_cast(nullif(split_part(version, '.', 1), '') as integer) as version_major,
        try_cast(nullif(split_part(version, '.', 2), '') as integer) as version_minor,
        try_cast(nullif(split_part(version, '.', 3), '') as integer) as version_build,

        -- ── payload: parsed downstream per event family ─────────────────
        cast(response as varchar) as response

    from deduped

)

select * from transformed
