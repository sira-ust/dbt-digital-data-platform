-- stg_nav__items — the NAV item master, one row per item_no. Cast, trim, and
-- turn the 0/1 merchandising flags into booleans. No filtering: blocked and
-- non-web items stay, because "why can I not sell this" is a question a rep
-- asks and an inner join upstream cannot answer.
--
-- THIS IS THE CATALOG SIDE OF THE ITEM. int_jdawms_items is the WAREHOUSE side
-- — ABC class, velocity zone, stock UOM, pick attributes — and the two are
-- joined in dim_items rather than here. item_no is the same SKU code as jdawms
-- prtmst.prtnum and the website sku (confirmed exact), so no normalisation.
--
-- THE THREE MERCHANDISING FLAGS ARE MANUAL, and the source docs are explicit
-- about it: popular_item is "a MANUAL buyer flag, not a computed velocity
-- measure", and new_item's persistence is unconfirmed — nobody has said how
-- long an item stays new. Neither is evidence of demand. They are what a buyer
-- chose to highlight, which is exactly the right input for "what should I pitch
-- them", and exactly the wrong input for "what sells". mart_account_item_history
-- keeps them apart from the measured purchase history for that reason.
--
-- No dedupe: item_no is the source PK and the pipeline is a full load keeping
-- only the latest runDate. The `unique` test is the guard rather than a silent
-- row_number() that would hide a real ingestion fault.

with source as (

    select * from {{ source('nav', 'item') }}

)

select
    nullif(trim(cast(item_no as {{ dbt.type_string() }})), '')             as item_no,

    -- TWO NAMES, and they are not redundant. description is the short label NAV
    -- shows in a list; full_description is the source's own "richest label
    -- available" and is what belongs in a spoken answer. Both are published so a
    -- consumer picks rather than guesses — and because full_description is not
    -- guaranteed populated, item_label below is the safe one to read.
    nullif(trim(cast(description      as {{ dbt.type_string() }})), '')    as item_description,
    nullif(trim(cast(full_description as {{ dbt.type_string() }})), '')    as item_full_description,
    coalesce(
        nullif(trim(cast(full_description as {{ dbt.type_string() }})), ''),
        nullif(trim(cast(description      as {{ dbt.type_string() }})), ''),
        nullif(trim(cast(item_no          as {{ dbt.type_string() }})), '')
    )                                                                      as item_label,
    nullif(trim(cast(body_description as {{ dbt.type_string() }})), '')    as item_body_description,

    -- ── taxonomy. NAV's OWN, and not the website's ────────────────────────
    -- item_category_code joins to nav item_category; seed_categories is the
    -- WEBSITE taxonomy on an unrelated numbering system. The source docs say the
    -- two "must never be merged", so nothing here touches seed_categories.
    nullif(trim(cast(item_category_code as {{ dbt.type_string() }})), '')  as item_category_code,
    nullif(trim(cast(product_group_code as {{ dbt.type_string() }})), '')  as product_group_code,
    nullif(trim(cast(item_family_no     as {{ dbt.type_string() }})), '')  as item_family_no,

    -- ── the merchandising flags. MANUAL. See the header ───────────────────
    (coalesce(cast(new_item     as {{ dbt.type_int() }}), 0) = 1)          as is_new_item,
    (coalesce(cast(popular_item as {{ dbt.type_int() }}), 0) = 1)          as is_popular_item,
    (coalesce(cast(show_on_web  as {{ dbt.type_int() }}), 0) = 1)          as is_shown_on_web,
    (coalesce(cast(app_banner   as {{ dbt.type_int() }}), 0) = 1)          as is_app_banner,

    -- ── price ─────────────────────────────────────────────────────────────
    -- LIST price per base UOM, not what any account actually paid. For that,
    -- use the invoice line's own amount. This is what prices an item the
    -- account has never bought, which is the whole reason it is here.
    cast(unit_price as {{ dbt.type_numeric() }})                           as unit_price,

    -- ── lifecycle ─────────────────────────────────────────────────────────
    -- discontinued is being phased out; blocked stops it transacting outright.
    -- Both matter to a recommendation and they are not the same thing.
    (coalesce(cast(discontinued as {{ dbt.type_int() }}), 0) = 1)          as is_discontinued,

    -- ── focus and new WINDOWS — both unmaintained in NAV. Read the note ───
    -- Dates go through nav_date() because NAV writes an unset date as
    -- 1753-01-01, not NULL, and a BETWEEN against that sentinel is silently
    -- false rather than an error.
    --
    -- WHAT THE SOURCE ACTUALLY HOLDS, measured 2026-09-23:
    --   focus_item   5 items of 7,573, four with a window from JULY 2017
    --   new_item   357 items, with new_end_date BLANK ON ALL 357
    -- So neither window can ever be satisfied today, and a model that gates on
    -- them shows zero. That is the honest result, not a bug to work around.
    -- The column that IS maintained is Marked New Date / Removed New Date
    -- (357 marked, 0 removed) — not yet in the ADF export.
    (coalesce(cast(focus_item as {{ dbt.type_int() }}), 0) = 1)            as is_focus_item,
    {{ nav_date('focus_begin_date') }}                                     as focus_begin_date,
    {{ nav_date('focus_end_date') }}                                       as focus_end_date,
    {{ nav_date('new_begin_date') }}                                       as new_begin_date,
    {{ nav_date('new_end_date') }}                                         as new_end_date,

    -- blocked is the ONE flag that is not merchandising: 1 stops the item
    -- transacting at all, so it is the gate on whether an item may be
    -- recommended. Kept as a positive is_sellable alongside, because a
    -- double negative in a filter is how a blocked item gets pitched.
    (coalesce(cast(blocked as {{ dbt.type_int() }}), 0) = 1)               as is_blocked,
    (coalesce(cast(blocked as {{ dbt.type_int() }}), 0) = 0)               as is_sellable,

    -- ── pack and size ─────────────────────────────────────────────────────
    nullif(trim(cast(base_unit_of_measure as {{ dbt.type_string() }})), '') as base_uom,
    nullif(trim(cast(basic_uom_size       as {{ dbt.type_string() }})), '') as basic_uom_size,
    nullif(trim(cast(size_unit            as {{ dbt.type_string() }})), '') as size_unit,
    cast(case_qty      as {{ dbt.type_numeric() }})                        as case_qty,
    cast(innerpack_qty as {{ dbt.type_numeric() }})                        as innerpack_qty,
    cast(ea_qty        as {{ dbt.type_numeric() }})                        as ea_qty,
    cast(cs_per_pallet as {{ dbt.type_numeric() }})                        as cs_per_pallet,
    cast(gross_weight  as {{ dbt.type_numeric() }})                        as gross_weight,

    nullif(trim(cast(country_region_of_origin_code as {{ dbt.type_string() }})), '')
                                                                           as country_of_origin,
    nullif(trim(cast(upc_code_1          as {{ dbt.type_string() }})), '') as upc_code,
    nullif(trim(cast(attributes1_flavor  as {{ dbt.type_string() }})), '') as attribute_flavor,
    nullif(trim(cast(attributes2_size_other as {{ dbt.type_string() }})), '')
                                                                           as attribute_size_other,
    nullif(trim(cast(attributes3_package as {{ dbt.type_string() }})), '') as attribute_package,

    cast(loaddate as timestamp)                                            as loaded_at
from source
where item_no is not null
