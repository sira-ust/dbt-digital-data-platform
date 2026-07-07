-- incremental_strategy switches by engine: Databricks can't do `delete+insert`
-- and DuckDB (dev) can't do `merge`. Both do the same thing — update the row if
-- the unique_key already exists, insert it if not — so this one line keeps the
-- model working on both targets.
{{ config(
    materialized='incremental',
    unique_key='entity_id',
    incremental_strategy=('merge' if target.type == 'databricks' else 'delete+insert'),
    on_schema_change='append_new_columns'
) }}

-- fct_events — published event-grain fact: the denormalised event spine.
-- One row per system_event_log record = int_events_enriched (decoded spine +
-- event-dictionary and app-source joins) materialised for BI, plus the raw
-- `response` payload.
--
-- NO payload-derived columns. Per-family parsed fields (cart sku/qty, search
-- query, viewed sku, catalog dwell, price overrides, feature titles) are NOT
-- pre-computed here — the payload format is non-JSON and drifts by app version,
-- so each field is parsed just-in-time from `response` when a dashboard actually
-- needs it (and can validate it). This keeps the fact to robust passthroughs and
-- avoids carrying fragile regex for columns no consumer reads yet.

with e as (

    select * from {{ ref('int_events_enriched') }}

    {% if is_incremental() %}
    -- Reprocess a trailing window so late-arriving / clock-skewed events (event_at_utc
    -- is device-local time) are picked up; merge on entity_id makes it idempotent.
    -- Widen the 3-day window if your ingestion lag is longer.
    where event_at_utc >= (
        select {{ dbt.dateadd('day', -3, "coalesce(max(event_at_utc), cast('1900-01-01' as timestamp))") }}
        from {{ this }}
    )
    {% endif %}

)

select
    entity_id,
    event_at_utc,
    customer_key,
    actor_type,
    source_code,
    app_name,
    app_platform,
    app_user_type,
    sales_code,
    username,
    description_code,
    l1_code,
    l2_code,
    l3_code,
    l4_code,
    function_name,
    l1_category_name,
    latitude,
    longitude,
    response
from e
