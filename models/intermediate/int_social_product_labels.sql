{{ config(tags=['social']) }}
-- int_social_product_labels — one label per canonical product: product_type (branded /
-- shelf / generic) and brand, with two layers on top of the LLM's label
-- (stg_mentionlytics__product_profile):
--
--   1. seed_social_product_overrides — a person's correction always wins. The LLM labels
--      22k products once; the few wrong ones that matter sit at the top of the board,
--      and fixing those by hand is cheaper and more certain than another LLM pass.
--      Leave product_type or brand blank in the seed to keep the LLM's value for it.
--   2. ONE SPELLING PER BRAND. The LLM wrote 71 brands more than one way ("Lay's" /
--      "Lays", "7-Eleven" / "7 Eleven"). brand_key folds them (case, accents,
--      apostrophes, hyphens, dots, spaces removed); brand is the spelling carried by
--      the most posts. Promo matching and the board's related-variants list both join
--      on brand_key.
--
-- A product with no LLM label and no override has no row; the board ranks it as generic.

with profiles as (

    select product_key, product_type, brand
    from {{ ref('stg_mentionlytics__product_profile') }}

),

overrides as (

    select
        nullif(trim(cast(product_key as {{ dbt.type_string() }})), '')     as product_key,
        nullif(lower(trim(cast(product_type as {{ dbt.type_string() }}))), '') as product_type,
        nullif(trim(cast(brand as {{ dbt.type_string() }})), '')           as brand
    from {{ ref('seed_social_product_overrides') }}

),

product_posts as (

    select product_key, max(product_mentions) as posts
    from {{ ref('int_social_concept_canon') }}
    group by 1

),

labelled as (

    select
        coalesce(p.product_key, o.product_key)                         as product_key,
        coalesce(o.product_type, p.product_type)                       as product_type,
        coalesce(o.brand, p.brand)                                     as brand_raw,
        o.product_key is not null                                      as is_overridden
    from profiles as p
    full outer join overrides as o
        on o.product_key = p.product_key

),

keyed as (

    select
        l.*,
        case when l.brand_raw is not null then
            {{ fold_concept("replace(replace(replace(replace(replace(replace(l.brand_raw, '''', ''), '’', ''), '-', ''), '.', ''), ' ', ''), '&', 'and')") }}
        end                                                            as brand_key,
        coalesce(pp.posts, 0)                                          as posts
    from labelled as l
    left join product_posts as pp
        on pp.product_key = l.product_key

),

brand_names as (

    select brand_key, brand_raw as brand
    from (
        select
            brand_key,
            brand_raw,
            row_number() over (
                partition by brand_key order by sum(posts) desc, brand_raw
            )                                                          as _rn
        from keyed
        where brand_key is not null
        group by brand_key, brand_raw
    ) as b
    where _rn = 1

)

select
    k.product_key,
    k.product_type,
    bn.brand,
    k.brand_key,
    k.is_overridden
from keyed as k
left join brand_names as bn
    on bn.brand_key = k.brand_key
where k.product_type in ('branded', 'shelf', 'generic')
