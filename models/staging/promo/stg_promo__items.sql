-- One row per promo-workbook row, typed. The landing table is append-only and a
-- month can be re-dropped (a corrected workbook), so only the LATEST load of each
-- promo_month is kept — whole-file replacement, never a row-by-row merge, because a
-- corrected workbook can drop rows as well as fix them.
--
-- Grain: (promo_month, promo_sheet, row_order). NOT item_no: nothing stops the same
-- item appearing on both sheets, and the output must keep both rows in place.

with source as (

    select * from {{ source('promo', 'promo_items') }}

),

typed as (

    select
        cast(promo_month as date)                                                as promo_month,
        nullif(trim(cast(promo_sheet as {{ dbt.type_string() }})), '')          as promo_sheet,
        cast(sheet_order as integer)                                             as sheet_order,
        cast(row_order as integer)                                               as row_order,
        nullif(trim(cast(item_no as {{ dbt.type_string() }})), '')              as item_no,
        nullif(trim(cast(description as {{ dbt.type_string() }})), '')          as promo_description,
        nullif(trim(cast(size as {{ dbt.type_string() }})), '')                 as promo_size,
        nullif(trim(cast(promo_code as {{ dbt.type_string() }})), '')           as promo_code,
        nullif(trim(cast(vendor_no as {{ dbt.type_string() }})), '')            as vendor_no,
        try_cast(starting_date as date)                                          as promo_starts_on,
        try_cast(ending_date as date)                                            as promo_ends_on,
        try_cast(loaded_at as timestamp)                                         as loaded_at,
        nullif(trim(cast(source_file as {{ dbt.type_string() }})), '')          as source_file
    from source

),

latest_load as (

    select
        *,
        dense_rank() over (
            partition by promo_month
            order by loaded_at desc, source_file desc
        ) as _load_rank
    from typed

)

select
    promo_month,
    promo_sheet,
    sheet_order,
    row_order,
    item_no,
    promo_description,
    promo_size,
    promo_code,
    vendor_no,
    promo_starts_on,
    promo_ends_on,
    loaded_at,
    source_file
from latest_load
where _load_rank = 1
