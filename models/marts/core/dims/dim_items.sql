-- dim_items — one row per item_no. The conformed item dimension: the name to
-- say out loud, what kind of thing it is, whether it may be sold at all, and
-- whether the warehouse can ship it today.
--
-- int_jdawms_items has carried a note since it was written calling itself "the
-- future dim_items surface for Unity Catalog / Genie". This is that surface. It
-- is not a rename of that model — it is the NAV CATALOG joined to the WMS
-- WAREHOUSE view, which have never been in one place before:
--
--   nav item        name, category, pack size, the manual merchandising flags
--   jdawms prtmst   ABC class, velocity zone, stock UOM  (via int_jdawms_items)
--   jdawms inv_snap what is shippable right now          (via the daily snapshot)
--
-- SPINE IS NAV, LEFT-JOINING THE WMS. Deliberately, and the reverse would be
-- wrong: NAV is the catalog of what the company sells, the WMS mirror covers
-- warehouse CABOT only, and an item that ships from an unmirrored site is a real
-- sellable item with no WMS row. Spining on the WMS would delete it. has_wms_item
-- says which case a row is, the same way dim_customers.has_coordinates does for
-- an ungeocodable address — an item with no WMS row has stock that is UNKNOWN,
-- not zero, and nothing may report it as out of stock.
--
-- STOCK IS A SNAPSHOT AND IT IS ONE WAREHOUSE. shippable_qty is the latest
-- CABOT snapshot, generated around 23:00 UTC the previous day. So "in stock"
-- here means "CABOT could ship it as of last night", which is the honest
-- reading and is exactly what a rep needs before promising an item. An item
-- showing zero here may still ship from a site the replica does not mirror.
--
-- EVERY ITEM IS HERE, including blocked ones and ones with no WMS row, for the
-- same reason dim_customers keeps inactive accounts: "why can I not sell this"
-- is a question, and an inner join upstream cannot answer it.

with nav_items as (

    select * from {{ ref('stg_nav__items') }}

),

-- The WMS item, already made readable — English descriptions resolved, ABC
-- class decoded, the CABOT template override applied. One row per prtnum +
-- prt_client_id there; collapsed to one row per prtnum here, because the item
-- code is what NAV and the app both speak and a second client id would fan the
-- dimension out. Ordered so the pick is deterministic rather than whichever row
-- the engine happened to return.
wms_items as (

    select
        prtnum,
        prt_client_id,
        item_name,
        item_short_name,
        item_family,
        abc_class,
        abc_class_description,
        velocity_zone,
        stock_uom,
        display_uom,
        row_number() over (partition by prtnum order by prt_client_id)    as _rn
    from {{ ref('int_jdawms_items') }}

),

-- The most recent stock snapshot per item, across whatever warehouses the
-- mirror covers (CABOT only today — summed rather than picked, so the day the
-- mirror gains a second site this keeps meaning "what we can ship" instead of
-- silently reporting one site).
latest_snapshot_date as (

    select max(snapshot_date) as snapshot_date
    from {{ ref('int_jdawms_inventory_daily') }}

),

stock as (

    select
        i.prtnum,
        i.snapshot_date,
        sum(i.shippable_qty)                                              as shippable_qty,
        sum(i.on_hand_qty)                                                as on_hand_qty,
        count(distinct i.wh_id)                                           as stocking_warehouses
    from {{ ref('int_jdawms_inventory_daily') }} as i
    join latest_snapshot_date as l on l.snapshot_date = i.snapshot_date
    group by i.prtnum, i.snapshot_date

),

-- NAV's own category taxonomy, with the ABC-style velocity flags that sit at
-- CATEGORY level. Distinct from the item-level abc_class above, which is the
-- WMS's cycle-counting class — different grain, different intent, so both are
-- published rather than reconciled into one field that would mean neither.
--
-- DEDUPED ON item_category_code, and it is not a formality. The source docs
-- call that column the PK, but navrep.item_category does NOT honour it — the
-- data carries several rows per code. Joined raw, this dimension fanned out
-- 8.7x: 200 items became 1,744 rows, every downstream count inflated by the
-- same factor, and nothing in the output looked obviously wrong. The `unique`
-- test on dim_items.item_no is the guard that keeps it caught.
--
-- The row kept is arbitrary but DETERMINISTIC (ordered by description, then the
-- velocity flags), so a rebuild cannot silently swap one category name for
-- another between runs. Which duplicate is CORRECT is a question for the dev
-- team; picking stably is the most this model can honestly do about it.
categories_raw as (

    select
        nullif(trim(cast(item_category_code as {{ dbt.type_string() }})), '')
                                                                          as item_category_code,
        nullif(trim(cast(description as {{ dbt.type_string() }})), '')     as item_category_name,
        (coalesce(cast(fast_item    as {{ dbt.type_int() }}), 0) = 1)      as category_is_fast_moving,
        (coalesce(cast(good_item    as {{ dbt.type_int() }}), 0) = 1)      as category_is_good_moving,
        (coalesce(cast(average_item as {{ dbt.type_int() }}), 0) = 1)      as category_is_average_moving,
        (coalesce(cast(slow_item    as {{ dbt.type_int() }}), 0) = 1)      as category_is_slow_moving
    from {{ source('nav', 'item_category') }}

),

-- Columns listed explicitly rather than `select *`: the `* except` / `* exclude`
-- spelling differs between databricks and duckdb, so neither is portable here.
-- Same reason int_events_enriched lists its columns out.
categories as (

    select
        item_category_code,
        item_category_name,
        category_is_fast_moving,
        category_is_good_moving,
        category_is_average_moving,
        category_is_slow_moving
    from (
        select
            c.item_category_code,
            c.item_category_name,
            c.category_is_fast_moving,
            c.category_is_good_moving,
            c.category_is_average_moving,
            c.category_is_slow_moving,
            row_number() over (
                partition by c.item_category_code
                order by c.item_category_name,
                         c.category_is_fast_moving, c.category_is_good_moving,
                         c.category_is_average_moving, c.category_is_slow_moving
            )                                                             as _rn
        from categories_raw as c
        where c.item_category_code is not null
    ) as ranked
    where _rn = 1

),

-- Is the item on a LIVE promotion as of the newest stock snapshot — i.e. as of
-- the same "today" every other column here is measured at, so the dimension
-- cannot disagree with itself about the date.
--
-- Aggregated to one row per item on purpose: an item can sit on several
-- promotions at once and this dimension must not fan out. The COUNT is
-- published so a consumer can see when that happened.
live_promotions as (

    select
        p.item_no,
        count(*)                                                          as live_promotion_count,
        min(p.promo_begin_date)                                           as promo_begin_date,
        max(p.promo_end_date)                                             as promo_end_date,
        -- THE OFFER, not the price. sprice is zero on every promotion live
        -- today in NAV, so promo_price is almost always null; the buy-X-get-Y
        -- pair is what is actually maintained and what makes a promo worth
        -- mentioning. max() picks the best offer where an item sits on several.
        max(p.promo_price)                                                as promo_price,
        max(p.promo_buy_qty)                                              as promo_buy_qty,
        max(p.promo_free_qty)                                             as promo_free_qty,
        max(case when p.has_promo_offer then 1 else 0 end) = 1            as has_promo_offer
    from {{ ref('stg_nav__promotion_lines') }} as p
    cross join latest_snapshot_date as l
    where p.is_live_promo_line
      and p.promo_begin_date is not null
      and p.promo_end_date   is not null
      and l.snapshot_date between p.promo_begin_date and p.promo_end_date
    group by p.item_no

)

select
    n.item_no,

    -- ── what to call it ───────────────────────────────────────────────────
    -- item_label is the one to READ OUT: NAV's full description where it
    -- exists, its short description otherwise, and the item number as a last
    -- resort so a spoken answer never says "null". The WMS long description is
    -- carried beside it rather than folded in, because the two systems name
    -- items differently and a consumer comparing a report to the warehouse
    -- floor needs to see both.
    n.item_label,
    n.item_description,
    n.item_full_description,
    w.item_name                                                           as wms_item_name,

    -- ── taxonomy. NAV's, never the website's ──────────────────────────────
    n.item_category_code,
    c.item_category_name,
    n.product_group_code,
    n.item_family_no,
    w.item_family                                                         as wms_item_family,

    -- ── may it be sold at all ─────────────────────────────────────────────
    -- is_blocked stops the item transacting in NAV. is_sellable is the same
    -- fact stated positively, because a filter written as `not is_blocked` is
    -- how a blocked item ends up recommended.
    n.is_blocked,
    n.is_sellable,
    n.is_shown_on_web,

    -- ── price ─────────────────────────────────────────────────────────────
    -- LIST price, which is what an item costs when the account has never
    -- bought it. For what they actually paid, mart_account_item_history
    -- carries their own invoiced value.
    n.unit_price,

    -- ── lifecycle ─────────────────────────────────────────────────────────
    -- Being phased out. NOT the same as blocked, which stops the item
    -- transacting outright — a discontinued item still sells, it just should
    -- not be built into a long-term recommendation.
    n.is_discontinued,

    -- ── focus and new, WITH THEIR WINDOWS — both unmaintained in NAV ──────
    -- is_focus_now and is_new_now are computed the way they SHOULD work, and
    -- both currently return false for every item in the catalogue. That is not
    -- a bug in this model: measured 2026-09-23, only 5 items carry the focus
    -- flag and four of those have a window from JULY 2017, while all 357
    -- new-flagged items have a BLANK new_end_date, so no window can be
    -- satisfied.
    --
    -- Published anyway, and computed correctly, so that the day the business
    -- starts maintaining the dates these begin working with no code change.
    -- Until then, read the raw flags and ignore the _now columns.
    n.is_focus_item,
    n.focus_begin_date,
    n.focus_end_date,
    case
        when n.focus_begin_date is null or n.focus_end_date is null then false
        else n.is_focus_item
             and l.snapshot_date between n.focus_begin_date and n.focus_end_date
    end                                                                   as is_focus_now,
    n.new_begin_date,
    n.new_end_date,
    case
        when n.new_begin_date is null or n.new_end_date is null then false
        else n.is_new_item
             and l.snapshot_date between n.new_begin_date and n.new_end_date
    end                                                                   as is_new_now,

    -- ── the MANUAL merchandising flags ────────────────────────────────────
    -- A buyer set these by hand. They are NOT measured demand: the source docs
    -- call popular_item "a MANUAL buyer flag, not a computed velocity measure",
    -- and how long new_item persists is unconfirmed — an item flagged new may
    -- have been new two years ago. Right input for "what should I pitch";
    -- wrong input for "what sells". Never let these stand in for the purchase
    -- history in int_customer_item_purchases.
    n.is_new_item,
    n.is_popular_item,
    n.is_app_banner,

    -- ── on promotion right now ────────────────────────────────────────────
    -- Measured as of stock_snapshot_date, the same "today" as the stock
    -- columns. Promotions have no NAME here — see stg_nav__promotion_lines for
    -- why the header join is unresolved.
    (p.item_no is not null)                                               as is_on_promotion,
    coalesce(p.live_promotion_count, 0)                                   as live_promotion_count,
    p.promo_begin_date,
    p.promo_end_date,
    -- NULL on almost every promotion — NAV does not set a price on live ones.
    -- Never render a null here as free or as zero.
    p.promo_price,
    -- "buy 6 get 1 free" — the part a rep can actually say out loud.
    p.promo_buy_qty,
    p.promo_free_qty,
    coalesce(p.has_promo_offer, false)                                    as has_promo_offer,

    -- ── velocity, at TWO different grains. Both published, neither merged ──
    -- abc_class is the WMS's ITEM-level cycle-counting class; the category_is_*
    -- flags are NAV's CATEGORY-level merchandising classes. They answer
    -- different questions and disagreeing is not an error.
    w.abc_class,
    w.abc_class_description,
    w.velocity_zone,
    c.category_is_fast_moving,
    c.category_is_good_moving,
    c.category_is_average_moving,
    c.category_is_slow_moving,

    -- ── pack and size ─────────────────────────────────────────────────────
    n.base_uom,
    w.stock_uom                                                           as wms_stock_uom,
    w.display_uom                                                         as wms_display_uom,
    n.basic_uom_size,
    n.size_unit,
    n.case_qty,
    n.innerpack_qty,
    n.ea_qty,
    n.cs_per_pallet,
    n.gross_weight,
    n.country_of_origin,
    n.upc_code,

    -- ── can the warehouse ship it ─────────────────────────────────────────
    -- THE HONESTY FLAG, and the reason this dimension spines on NAV. False
    -- means the item has no row in the WMS mirror at all — its stock is
    -- UNKNOWN, not zero, and nothing may report it as out of stock. The WMS
    -- mirror covers warehouse CABOT only, so an item shipping from an
    -- unmirrored site lands here.
    (w.prtnum is not null)                                                as has_wms_item,
    s.snapshot_date                                                       as stock_snapshot_date,
    s.shippable_qty,
    s.on_hand_qty,
    coalesce(s.stocking_warehouses, 0)                                    as stocking_warehouses,
    -- Three-valued on purpose: true / false / NULL, where NULL is "the mirror
    -- does not cover this item". A consumer that treats null as false will tell
    -- a rep an item is out of stock when the truth is that we cannot see it.
    case
        when w.prtnum is null then null
        else coalesce(s.shippable_qty, 0) > 0
    end                                                                   as is_in_stock,

    n.loaded_at
from nav_items as n
cross join latest_snapshot_date as l
left join wms_items      as w on w.prtnum = n.item_no and w._rn = 1
left join stock          as s on s.prtnum = n.item_no
left join categories     as c on c.item_category_code = n.item_category_code
left join live_promotions as p on p.item_no = n.item_no
