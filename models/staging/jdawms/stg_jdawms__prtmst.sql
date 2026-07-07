-- Staging for jdawms.prtmst — 1:1 lossless view over the raw WMS replica.
-- All 28 source columns preserved as-is (types already clean in Delta).
-- Databricks reads the real replica; DuckDB reads mock parquet (see data/README.md).

with source as (
    select * from {{ source('jdawms', 'prtmst') }}
)

select
    prtnum,
    prt_client_id,
    wh_id_tmpl,
    prtfam,
    dsp_prtnum,
    age_pflnam,
    lodlvl,
    orgflg,
    revflg,
    lotflg,
    sup_lot_flg,
    stkuom,
    abccod,
    fifwin,
    velzon,
    rcvsts,
    rcvflg,
    prdflg,
    wgtcod,
    prtfit,
    moddte,
    mod_usr_id,
    dspuom,
    rptuom,
    dte_win_typ,
    dte_code,
    ordinv,
    loaddate
from source
