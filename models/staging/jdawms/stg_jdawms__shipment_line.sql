-- Staging for jdawms.shipment_line — 1:1 lossless view over the raw WMS replica.
-- All 49 source columns preserved as-is (types already clean in Delta).
-- Cross-source join keys (prtnum, prt_client_id) are whitespace-trimmed to
-- match the trimmed MySQL side; WMS CHAR columns can be space-padded.
-- Databricks reads the real replica; DuckDB reads mock parquet (see data/README.md).

with source as (
    select * from {{ source('jdawms', 'shipment_line') }}
)

select
    ship_line_id,
    ship_id,
    wh_id,
    client_id,
    ordnum,
    ordlin,
    ordsln,
    cons_batch,
    shpwth,
    linsts,
    prcpri,
    pckgr1,
    pckgr2,
    pckgr3,
    pckgr4,
    schbat,
    pckqty,
    inpqty,
    stgqty,
    shpqty,
    oviqty,
    ovramt,
    ovrcod,
    edtflg,
    tot_pln_cas_qty,
    tot_pln_misc2_qty,
    tot_pln_wgt,
    tot_pln_cube,
    tot_pln_misc_qty,
    tot_pln_pal_qty,
    tot_pln_qty,
    unt_ins_val,
    rel_val,
    rel_val_unt_typ,
    wkonum,
    wkorev,
    moddte,
    mod_usr_id,
    dstr_qty,
    trim(prtnum) as prtnum,
    trim(prt_client_id) as prt_client_id,
    est_time,
    picked_qty,
    instgqty,
    inloadqty,
    ftpcod,
    untpal,
    _rescued_data,
    loaddate
from source
