-- Staging for jdawms.rplcfg — 1:1 lossless view over the raw WMS replica.
-- All 18 source columns preserved as-is (types already clean in Delta).
-- Databricks reads the real replica; DuckDB reads mock parquet (see data/README.md).

with source as (
    select * from {{ source('jdawms', 'rplcfg') }}
)

select
    rplnum,
    wh_id,
    prtnum,
    prt_client_id,
    stoloc,
    mov_zone_id,
    invsts,
    pctflg,
    maxunt,
    minunt,
    maxloc,
    cmpflg,
    rpldte,
    inc_pct_flg,
    inc_unt,
    rls_pct,
    mod_usr_id,
    loaddate
from source
