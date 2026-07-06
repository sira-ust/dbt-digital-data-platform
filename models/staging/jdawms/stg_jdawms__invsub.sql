-- Staging for jdawms.invsub — 1:1 lossless view over the raw WMS replica.
-- All 28 source columns preserved as-is (types already clean in Delta).
-- Databricks-only (no local sample); materialized as a view (see dbt_project.yml).

with source as (
    select * from {{ source('jdawms', 'invsub') }}
)

select
    subnum,
    lodnum,
    subwgt,
    prmflg,
    phyflg,
    mvsflg,
    ctnflg,
    idmflg,
    distro_ctnopn_flg,
    wrkref,
    tagdev,
    adddte,
    lstmov,
    lstdte,
    lstcod,
    lst_usr_id,
    subucc,
    uccdte,
    subtag,
    sub_tagsts,
    asset_typ,
    est_subwgt,
    u_version,
    ins_dt,
    last_upd_dt,
    ins_user_id,
    last_upd_user_id,
    loaddate
from source
