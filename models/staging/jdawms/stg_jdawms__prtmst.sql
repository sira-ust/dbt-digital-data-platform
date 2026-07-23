-- Staging for jdawms.prtmst — 1:1 lossless view over the raw WMS replica.
-- All 28 source columns preserved as-is (types already clean in Delta).
-- Cross-source join keys (prtnum, prt_client_id, dsp_prtnum) are whitespace-
-- trimmed to match the trimmed MySQL side; WMS CHAR columns can be space-padded.
-- Databricks reads the real replica; DuckDB reads mock parquet (see data/README.md).

with source as (
    select * from {{ source('jdawms', 'prtmst') }}
)

select
    trim(prtnum) as prtnum,
    trim(prt_client_id) as prt_client_id,
    wh_id_tmpl,
    prtfam,
    trim(dsp_prtnum) as dsp_prtnum,
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
