-- Staging for jdawms.invlod — 1:1 lossless view over the raw WMS replica.
-- All 40 source columns preserved as-is (types already clean in Delta).
-- Databricks-only (no local sample); materialized as a view (see dbt_project.yml).

with source as (
    select * from {{ source('jdawms', 'invlod') }}
)

select
    lodnum,
    wh_id,
    stoloc,
    lodwgt,
    prmflg,
    unkflg,
    mvlflg,
    adddte,
    lstmov,
    lstdte,
    lstcod,
    lst_usr_id,
    loducc,
    uccdte,
    palpos,
    asset_typ,
    avg_unt_catch_qty,
    u_version,
    ins_dt,
    last_upd_dt,
    ins_user_id,
    last_upd_user_id,
    lodtag,
    lod_tagsts,
    lodhgt,
    bundled_flg,
    distro_palopn_flg,
    load_attr1_flg,
    load_attr2_flg,
    load_attr3_flg,
    load_attr4_flg,
    load_attr5_flg,
    no_loc_putaway,
    completed_receiving_date,
    est_time,
    lodlen,
    lodwdt,
    no_of_boxes,
    est_lodwgt,
    loaddate
from source
