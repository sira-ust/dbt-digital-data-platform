-- int_jdawms_sale_picks_daily — sale-shipment picking demand, one row per
-- item x pick date x temperature zone (pick_type), quantity in CASES. This is
-- the item-movement (demand) signal that feeds the weekly forecast pipeline
-- (exported today as SKU_movement.xlsx).
--
-- Source is the pick-work record (pckwrk_hdr + pckwrk_dtl), NOT the dlytrn
-- ledger: a row with a pckdte is a CONFIRMED pick, so demand here is already
-- net of cancels/unpicks. Cases are computed by DIVIDING picked units (pckqty)
-- by units-per-case (untcas) — never multiplying; rows that cannot convert
-- (untcas null or 0) are counted in bad_untcas_rows so the loss stays visible.
--
-- pick_type is the temperature zone, derived from the pick operation (oprcod)
-- and the source location's storage zone (locmst.sto_zone_id). Zone ids
-- 10002=DRY / 10004=FRZ are dev-confirmed magic numbers — keep the CASE
-- verbatim until a zone seed lands. UNCLASSIFIED = the pick's source location
-- had no locmst match (sto_zone_id null). The branch order is significant.
--
-- prt_client_id is carried to match the WMS composite item key used across the
-- other jdawms models (int_jdawms_items, int_jdawms_inventory_daily); the
-- forecast groups to prtnum only.
--
-- Generic pick-date grain on purpose: no rolling-window filter here (the
-- original SQL kept a trailing 8 months) — trailing windows and weekly rollups
-- belong to the reader (mart / pipeline).

with picks as (

    select
        hdr.prtnum,
        hdr.prt_client_id,
        cast(hdr.pckdte as date)                                        as pck_date,
        hdr.untcas,
        cast(dtl.pckqty as decimal(18, 4)) / nullif(hdr.untcas, 0)      as cases,  -- DIVIDE, never multiply
        case
            when hdr.oprcod = 'LPCKORD' and loc.sto_zone_id =  10002 then 'DRY'
            when hdr.oprcod = 'LPCKORD' and loc.sto_zone_id =  10004 then 'FRZ'
            when hdr.oprcod = 'PCK'     and loc.sto_zone_id <> 10004 then 'DRY'
            when loc.sto_zone_id is null                             then 'UNCLASSIFIED'
            else 'FRZ'
        end                                                             as pick_type
    from {{ ref('stg_jdawms__pckwrk_hdr') }} as hdr
    inner join {{ ref('stg_jdawms__pckwrk_dtl') }} as dtl
        on dtl.wrkref = hdr.wrkref
    left join {{ ref('stg_jdawms__locmst') }} as loc
        on hdr.wh_id = loc.wh_id
       and hdr.srcloc = loc.stoloc
    where hdr.pckdte is not null                                        -- confirmed picks only

)

select
    prtnum,
    prt_client_id,
    pck_date,
    pick_type,
    sum(cases)                                                          as total_cases,      -- picked qty in cases (forecast unit)
    sum(case when untcas is null or untcas = 0 then 1 else 0 end)       as bad_untcas_rows   -- rows that could NOT convert to cases
from picks
group by 1, 2, 3, 4
