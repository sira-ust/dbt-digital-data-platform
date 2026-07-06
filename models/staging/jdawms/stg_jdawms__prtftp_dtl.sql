-- Staging for jdawms.prtftp_dtl — 1:1 lossless view over the raw WMS replica.
-- All 27 source columns preserved as-is (types already clean in Delta).
-- Databricks-only (no local sample); materialized as a view (see dbt_project.yml).

with source as (
    select * from {{ source('jdawms', 'prtftp_dtl') }}
)

select
    prtnum,
    ftpcod,
    prt_client_id,
    wh_id,
    uomcod,
    uomlvl,
    len,
    wid,
    hgt,
    grswgt,
    netwgt,
    pal_flg,
    layer_flg,
    cas_flg,
    pak_flg,
    stk_flg,
    rcv_flg,
    untqty,
    ctn_flg,
    thresh_pct,
    ctn_dstr_flg,
    bulk_pck_flg,
    ins_dt,
    last_upd_dt,
    ins_user_id,
    last_upd_user_id,
    loaddate
from source
