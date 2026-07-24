-- int_jdawms_stock_weekly — weekly in-stock signal per item, Monday-anchored,
-- one row per item x warehouse x week. Rolls up the deduped daily snapshot
-- (int_jdawms_inventory_daily) to the week the forecast pipeline consumes as
-- its mandatory in-stock mask (exported today as SKU_stock_weekly.xlsx).
--
-- Mask reducer is "shippable on ANY day": in_stock = 1 if the item was
-- shippable (shippable_qty > 0) on at least one snapshot day in the week.
-- in_stock_all requires every day; instock_frac is the fraction of days
-- shippable. on_hand_qty / shippable_qty are the END-OF-WEEK values (the last
-- snapshot day in the week), matching mart_item_demand_supply's end-of-week
-- logic and the same row_number pattern.
--
-- Built on int_jdawms_inventory_daily (already one row per item-day, last
-- snapshot wins), so the day is the unit of the fraction — n_days counts the
-- snapshot days present, not raw snapshots. CABOT warehouse only (the replica
-- mirrors a single wh_id).
--
-- No rolling-window filter here (the original SQL kept a trailing 8 months) —
-- trailing windows belong to the reader (mart / pipeline).

with daily as (

    select
        prtnum,
        prt_client_id,
        wh_id,
        snapshot_at,
        on_hand_qty,
        shippable_qty,
        cast({{ dbt.date_trunc('week', 'snapshot_date') }} as date)     as week_start
    from {{ ref('int_jdawms_inventory_daily') }}

),

ranked as (

    -- tag the last snapshot day within each item-week for the end-of-week values
    select
        *,
        row_number() over (
            partition by prtnum, prt_client_id, wh_id, week_start
            order by snapshot_at desc
        )                                                               as _rn
    from daily

)

select
    prtnum,
    prt_client_id,
    wh_id,
    week_start,
    max(case when _rn = 1 then on_hand_qty end)                         as on_hand_qty,      -- end-of-week on hand
    max(case when _rn = 1 then shippable_qty end)                       as shippable_qty,    -- end-of-week shippable
    avg(case when shippable_qty > 0 then 1.0 else 0.0 end)              as instock_frac,     -- share of days shippable
    max(case when shippable_qty > 0 then 1 else 0 end)                  as in_stock,         -- 1 if shippable ANY day (the mask)
    min(case when shippable_qty > 0 then 1 else 0 end)                  as in_stock_all,     -- 1 only if shippable EVERY day
    count(*)                                                            as n_days
from ranked
group by 1, 2, 3, 4
