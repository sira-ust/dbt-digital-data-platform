-- Staging for jdawms.inv_snap — 1:1 lossless view over the raw WMS replica.
-- All 27 source columns preserved as-is (types already clean in Delta).
-- Databricks reads the real replica; DuckDB reads mock parquet (see data/README.md).

with source as (
    select * from {{ source('jdawms', 'inv_snap') }}
)

select
    inv_snap_id,
    prtnum,
    prt_client_id,
    gendte,
    rcvqty,
    shpqty,
    adjqty,
    wko_cnsqty,
    wko_rcvqty,
    on_hand_qty,
    shippable_qty,
    ordered_qty,
    planned_qty,
    wko_ordered_qty,
    pnd_rcvqty,
    wh_id,
    snap_gen_num,
    moddte,
    mod_usr_id,
    u_version,
    ins_dt,
    last_upd_dt,
    ins_user_id,
    last_upd_user_id,
    rowid,
    _rescued_data,
    loaddate
from source
