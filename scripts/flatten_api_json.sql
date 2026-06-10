-- ============================================================================
-- Ingestion prep: flatten raw API response JSON -> data/system_events.parquet
-- ============================================================================
-- The sample data is the raw API response (Laravel-style pagination envelope):
--   { code, msg, data: { current_page, data: [event records], per_page, total, ... } }
-- Event records live at data.data[]. There may be multiple files (one per
-- page) in data/raw_api/.
--
-- Run BEFORE dbt build (DuckDB-only script, not part of the dbt DAG):
--   duckdb -c ".read scripts/flatten_api_json.sql"
--
-- Idempotent: re-running overwrites data/system_events.parquet, and pages
-- that overlap are deduplicated on entity_id (keep latest updated_at).
-- ============================================================================

copy (
    with raw_pages as (

        -- matches data/*.json and data/raw_api/*.json alike
        select unnest("data"."data", recursive := true)
        from read_json_auto(
            'data/**/*.json',
            -- payload `response` strings must survive intact; keep as VARCHAR
            maximum_object_size = 67108864
        )

    ),

    deduped as (

        select *
        from raw_pages
        qualify row_number() over (
            partition by entity_id
            order by updated_at desc
        ) = 1

    )

    select * from deduped

) to 'data/system_events.parquet' (format parquet);

-- Sanity check — expect ~611,856 rows for the one-month sample:
select count(*) as flattened_rows from 'data/system_events.parquet';
