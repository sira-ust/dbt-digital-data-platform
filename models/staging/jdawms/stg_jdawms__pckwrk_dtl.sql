-- Staging for jdawms.pckwrk_dtl — 1:1 lossless view over the raw WMS replica.
-- All 53 source columns preserved as-is (types already clean in Delta).
-- Cross-source join keys (prtnum, prt_client_id, stcust) are whitespace-trimmed
-- to match the trimmed MySQL side; WMS CHAR columns can be space-padded.
-- Databricks reads the real replica; DuckDB reads mock parquet (see data/README.md).

with source as (
    select * from {{ source('jdawms', 'pckwrk_dtl') }}
)

select
    wrkref_dtl,
    wrkref,
    cmbcod,
    wh_id,
    client_id,
    dstloc,
    dst_mov_zone_id,
    ship_line_id,
    ship_id,
    ordnum,
    ordlin,
    ordsln,
    trim(stcust) as stcust,
    rtcust,
    concod,
    pckqty,
    pck_catch_qty,
    appqty,
    app_catch_qty,
    lodlvl,
    ship_ctncod,
    ship_ctnnum,
    wkonum,
    wkorev,
    wkolin,
    seqnum,
    subnum,
    dtlnum,
    subucc,
    subtag,
    cur_cas,
    tot_cas_cnt,
    prtdte,
    bto_seqnum,
    slot,
    bto_dlv_seq,
    lm_assign_num,
    lm_assign_seqnum,
    pm_err_cod,
    pm_err_desc,
    ctnerr_flg,
    res_uom,
    ins_dt,
    last_upd_dt,
    ins_user_id,
    last_upd_user_id,
    rowid,
    schbat,
    untcas,
    wrktyp,
    trim(prtnum) as prtnum,
    trim(prt_client_id) as prt_client_id,
    loaddate
from source
