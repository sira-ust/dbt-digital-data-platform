-- int_jdawms_inventory_daily — WMS stock position, one row per item x
-- warehouse x snapshot day. Thin cleanup of the inv_snap daily snapshot:
-- proper snapshot_date, deduped to the last snapshot generated per day.
-- Generic day grain on purpose — weekly rollups, thresholds and labels
-- belong to the marts that read this.
--
-- inv_snap is genuinely daily (verified 2026-07-13: 51 snapshots in 60
-- days, ~5.7k items each, shippable_qty 100% populated). Snapshots are
-- generated ~23:00 UTC. Coverage is warehouse CABOT only — the replica
-- mirrors a single wh_id.
--
-- ordered_qty / planned_qty / pnd_rcvqty are passed through under their WMS
-- names: their exact in/outbound semantics are not dev-confirmed yet, so no
-- renaming that would bake in a guess.
--
-- Materialized as a VIEW (overrides the intermediate table default): one
-- row_number over the staging view, read once per mart build.

{{ config(materialized='view') }}

with snaps as (

    select
        prtnum,
        prt_client_id,
        wh_id,
        cast({{ dbt.date_trunc('day', 'gendte') }} as date)             as snapshot_date,
        gendte                                                          as snapshot_at,
        shippable_qty,
        on_hand_qty,
        ordered_qty,
        planned_qty,
        pnd_rcvqty,
        rcvqty,
        shpqty,
        adjqty
    from {{ ref('stg_jdawms__inv_snap') }}
    where gendte is not null
      and prtnum is not null

),

deduped as (

    -- if the WMS generates more than one snapshot in a day, keep the latest
    select
        *,
        row_number() over (
            partition by prtnum, prt_client_id, wh_id, snapshot_date
            order by snapshot_at desc
        )                                                               as _rn
    from snaps

)

select
    prtnum,
    prt_client_id,
    wh_id,
    snapshot_date,
    snapshot_at,
    shippable_qty,
    on_hand_qty,
    ordered_qty,
    planned_qty,
    pnd_rcvqty,
    rcvqty,
    shpqty,
    adjqty
from deduped
where _rn = 1
