-- Staging for jdawms.rplcfg — 1:1 lossless view over the raw WMS replica.
-- All 18 source columns preserved as-is (types already clean in Delta).
-- Databricks-only (no local sample); materialized as a view (see dbt_project.yml).

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
