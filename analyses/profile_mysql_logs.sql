-- ============================================================================
-- Profiling / validation for the ustrading System Event Log sample
-- ============================================================================
-- Schema is now DOCUMENTED (API doc) — these queries validate the sample
-- against the spec and flag doc-vs-reality drift, rather than reverse-
-- engineering from scratch.
--
-- Run in the DuckDB CLI after the flatten step:
--   duckdb -c ".read scripts/flatten_api_json.sql"
--   duckdb
--   D .read analyses/profile_mysql_logs.sql
--
-- dbt compiles analyses/ but never runs them.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. Sanity: row count (expect ~611,856 for the one-month sample) and a peek
-- ----------------------------------------------------------------------------
select count(*) as row_count from 'data/system_events.parquet';

select * from 'data/system_events.parquet' limit 20;

summarize select * from 'data/system_events.parquet';


-- ----------------------------------------------------------------------------
-- 1. entity_id integrity: PK uniqueness + gap check
-- ----------------------------------------------------------------------------
select
    count(*) as rows,
    count(distinct entity_id) as distinct_ids,
    count(*) - count(distinct entity_id) as dup_rows,     -- expect 0 post-flatten
    max(entity_id) - min(entity_id) + 1 - count(distinct entity_id) as id_gaps
from 'data/system_events.parquet';


-- ----------------------------------------------------------------------------
-- 2. Event code distribution vs the seed dictionary
-- ----------------------------------------------------------------------------
-- Codes in the data but missing from seed_event_codes -> extend the seed.
select
    p.description_code,
    count(*) as rows,
    min(p.created_at) as first_seen,
    max(p.created_at) as last_seen
from 'data/system_events.parquet' p
left join read_csv('seeds/seed_event_codes.csv', header := true, all_varchar := true) s
    on p.description_code = s.description_code
where s.description_code is null
group by 1
order by 2 desc;


-- ----------------------------------------------------------------------------
-- 3. Payload presence/format vs seed expectations  ** FLAG, don't fail **
-- ----------------------------------------------------------------------------
-- Compares actual `response` payloads per description_code against the
-- payload_format expectation in seed_event_codes. The sample already proves
-- the doc wrong in places — e.g. 01020200 carries response: "1" despite the
-- doc saying no payload. Treat mismatches as findings to document in the
-- seed/yml, not as errors.
with classified as (
    select
        description_code,
        case
            when response is null or trim(response) = ''            then 'none'
            when response = 'Fail'                                   then 'fail_marker'
            when regexp_matches(response, '^Time:[0-9]+$')           then 'duration'
            when regexp_matches(response, '^[^,:]+:[^,]*(,[^,:]+:[^,]*)+$')
                                                                     then 'kv'
            when regexp_matches(response, '^[^,]+(,[^,]*){4,}$')     then 'positional_order'
            else 'bare_value'   -- SKU, title, or unexpected (like "1" on 01020200)
        end as observed_format,
        count(*) as rows
    from 'data/system_events.parquet'
    group by 1, 2
)
select
    c.description_code,
    s.function_name,
    s.payload_format as expected_format,
    c.observed_format,
    c.rows,
    case
        when s.description_code is null            then 'CODE NOT IN SEED'
        when s.payload_format <> c.observed_format then 'MISMATCH — investigate / document'
        else 'ok'
    end as finding
from classified c
left join read_csv('seeds/seed_event_codes.csv', header := true, all_varchar := true) s
    on c.description_code = s.description_code
where s.description_code is null or s.payload_format <> c.observed_format
order by c.rows desc;


-- ----------------------------------------------------------------------------
-- 4. Timestamp checks (informational — do NOT turn into tests)
-- ----------------------------------------------------------------------------
-- Device clock drift / offline queueing make event_time vs created_at
-- ordering unreliable by design; this just characterizes how bad it is.
select
    case
        when event_time is null then 'null_event_time'
        when (created_at + interval 8 hour)
           - (event_time - interval (coalesce(try_cast(regexp_extract(timezone, 'GMT([+-][0-9]{1,2})', 1) as integer), 0)) hour)
             < interval 0 second then 'event_after_created (drift/queueing)'
        when (created_at + interval 8 hour)
           - (event_time - interval (coalesce(try_cast(regexp_extract(timezone, 'GMT([+-][0-9]{1,2})', 1) as integer), 0)) hour)
             > interval 24 hour then 'event_>24h_before_created (offline queue)'
        else 'within_24h'
    end as drift_bucket,
    count(*) as rows
from 'data/system_events.parquet'
group by 1
order by 2 desc;

-- event_id epoch-millis sanity (should parse to plausible timestamps):
select
    count(*) filter (where try_cast(event_id as bigint) between 1.4e12 and 2.1e12) as plausible_epoch_ms,
    count(*) filter (where event_id is null or trim(event_id) = '') as null_or_empty,
    count(*) as total
from 'data/system_events.parquet';


-- ----------------------------------------------------------------------------
-- 5. Source / version / timezone distributions
-- ----------------------------------------------------------------------------
select source, count(*) as rows
from 'data/system_events.parquet'
group by 1 order by 2 desc;          -- expect exactly the 9 documented codes

select timezone, count(*) as rows
from 'data/system_events.parquet'
group by 1 order by 2 desc;          -- watch for half-hour offsets (GMT+5:30)

select source, version, count(*) as rows
from 'data/system_events.parquet'
group by 1, 2 order by 1, 3 desc;


-- ----------------------------------------------------------------------------
-- 6. Geo capture rate vs has_geo expectation
-- ----------------------------------------------------------------------------
select
    p.description_code,
    s.has_geo as expected_geo,
    count(*) filter (where p.location is not null and trim(p.location) <> '') as rows_with_geo,
    count(*) as rows
from 'data/system_events.parquet' p
left join read_csv('seeds/seed_event_codes.csv', header := true, all_varchar := true) s
    on p.description_code = s.description_code
group by 1, 2
having (s.has_geo = 'true') <> (count(*) filter (where p.location is not null and trim(p.location) <> '') > 0)
order by rows desc;
