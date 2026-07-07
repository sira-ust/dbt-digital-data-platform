-- Staging for jdawms.invsum — 1:1 lossless view over the raw WMS replica.
-- All 29 source columns preserved as-is (types already clean in Delta).
-- Databricks reads the real replica; DuckDB reads mock parquet (see data/README.md).

with source as (
    select * from {{ source('jdawms', 'invsum') }}
)

select
    stoloc,
    prtnum,
    prt_client_id,
    wh_id,
    arecod,
    invsts,
    untpak,
    untcas,
    untpal,
    untqty,
    comqty,
    pndqty,
    com_catch_qty,
    catch_qty,
    olddte,
    newdte,
    old_expire_dte,
    new_expire_dte,
    old_inv_attr_dte1,
    new_inv_attr_dte1,
    old_inv_attr_dte2,
    new_inv_attr_dte2,
    u_version,
    ins_dt,
    last_upd_dt,
    ins_user_id,
    last_upd_user_id,
    rowid,
    loaddate
from source
