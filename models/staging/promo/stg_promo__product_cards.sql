-- AI-drafted product cards, one row per item_no (latest draft wins). A card is drawn
-- from the item's product photo and the description file's text (the monthly INPUT
-- file): the brand, product and flavor as PRINTED on the pack, the pack, the market,
-- what it looks like and its lookalikes, plus the search phrases and extra match
-- terms taken from the pack. scripts/promo/draft_product_cards.py writes them; an item
-- with no photo and no description has no card. See int_promo_items_enriched.

with source as (

    select * from {{ source('promo', 'product_cards') }}

),

typed as (

    select
        nullif(trim(cast(item_no as {{ dbt.type_string() }})), '')           as item_no,
        nullif(trim(cast(brand_on_pack as {{ dbt.type_string() }})), '')     as brand_on_pack,
        nullif(trim(cast(product_on_pack as {{ dbt.type_string() }})), '')   as product_on_pack,
        nullif(trim(cast(flavor_on_pack as {{ dbt.type_string() }})), '')    as flavor_on_pack,
        nullif(trim(cast(pack as {{ dbt.type_string() }})), '')              as pack,
        nullif(trim(cast(market as {{ dbt.type_string() }})), '')            as market,
        nullif(trim(cast(look as {{ dbt.type_string() }})), '')              as look,
        nullif(trim(cast(pack_text as {{ dbt.type_string() }})), '')         as pack_text,
        nullif(trim(cast(lookalikes as {{ dbt.type_string() }})), '')        as lookalikes,
        nullif(trim(cast(search_phrases as {{ dbt.type_string() }})), '')    as search_phrases,
        nullif(trim(cast(flavor_terms as {{ dbt.type_string() }})), '')      as flavor_terms,
        nullif(trim(cast(product_terms as {{ dbt.type_string() }})), '')     as product_terms,
        lower(trim(cast(has_photo as {{ dbt.type_string() }}))) = 'true'     as has_photo,
        nullif(trim(cast(notes as {{ dbt.type_string() }})), '')             as notes,
        nullif(trim(cast(input_fingerprint as {{ dbt.type_string() }})), '') as input_fingerprint,
        try_cast(drafted_at as timestamp)                                     as drafted_at,
        nullif(trim(cast(card_version as {{ dbt.type_string() }})), '')      as card_version
    from source

),

numbered as (

    select *, row_number() over (partition by item_no order by drafted_at desc) as _rn
    from typed
    where item_no is not null

)

select
    item_no, brand_on_pack, product_on_pack, flavor_on_pack, pack, market, look, pack_text,
    lookalikes, search_phrases, flavor_terms, product_terms, has_photo, notes,
    input_fingerprint, drafted_at, card_version
from numbered
where _rn = 1
