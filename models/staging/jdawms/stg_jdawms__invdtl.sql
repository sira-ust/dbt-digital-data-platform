-- Staging for jdawms.invdtl — 1:1 lossless view over the raw WMS replica.
-- All 26 source columns preserved as-is (types already clean in Delta).
-- Databricks reads the real replica; DuckDB reads mock parquet (see data/README.md).

with source as (
    select * from {{ source('jdawms', 'invdtl') }}
)

select
    dtlnum,
    subnum,
    prtnum,
    prt_client_id,
    invsts,
    fifdte,
    expire_dte,
    untqty,
    untcas,
    untpak,
    ftpcod,
    rcvkey,
    ship_line_id,
    wrkref,
    wrkref_dtl,
    adddte,
    rcvdte,
    lstmov,
    lstdte,
    lstcod,
    lst_usr_id,
    alcflg,
    catch_qty,
    lst_mov_zone_id,
    hld_flg,
    loaddate
from source
