-- Staging for jdawms.prtftp — 1:1 lossless view over the raw WMS replica.
-- All 24 source columns preserved as-is (types already clean in Delta).
-- Cross-source join keys (prtnum, prt_client_id) are whitespace-trimmed to
-- match the trimmed MySQL side; WMS CHAR columns can be space-padded.
-- Databricks reads the real replica; DuckDB reads mock parquet (see data/README.md).

with source as (
    select * from {{ source('jdawms', 'prtftp') }}
)

select
    trim(prtnum) as prtnum,
    ftpcod,
    trim(prt_client_id) as prt_client_id,
    wh_id,
    caslvl,
    nstlen,
    nstwid,
    nsthgt,
    pal_stck_hgt,
    def_asset_typ,
    defftp_flg,
    stkmtd,
    load_attr1_cfg,
    load_attr2_cfg,
    load_attr3_cfg,
    load_attr4_cfg,
    load_attr5_cfg,
    rcvftp_flg,
    level_units,
    ins_dt,
    last_upd_dt,
    ins_user_id,
    last_upd_user_id,
    loaddate
from source
