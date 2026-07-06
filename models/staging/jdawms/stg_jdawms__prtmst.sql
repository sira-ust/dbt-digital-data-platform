-- Staging for jdawms.prtmst — 1:1 lossless view over the raw WMS replica.
-- All 28 source columns preserved as-is (types already clean in Delta).
-- Databricks-only (no local sample); materialized as a view (see dbt_project.yml).

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
