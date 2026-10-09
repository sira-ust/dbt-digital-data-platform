{{ config(tags=['social']) }}
{% set window_days = 7 * var('social_trend_variant_window_weeks') - 1 %}
-- int_social_product_variants — "which Pepsi? which Magnum?": for every product on the
-- board, its RELATED products and how much each was posted about recently. One row per
-- (week_start, board product), with top_variants like
--     pepsi         -> ['pepsi dubai chocolate (10)', 'pepsi treats (3)', 'pepsi zero (1)']
--     tiramisu      -> ['tiramisu cupcake (25)', 'tiramisu cake (10)', 'matcha tiramisu (2)']
--
-- DETERMINISTIC on purpose. An LLM pass asking each product for its "family" and
-- "variant" was tried on 300 products (2026-10-06) and grouped one family several ways
-- depending only on batch order, so the relation is derived instead:
--   * a BRANDED product's related products are the other products of the same brand
--     (int_social_product_labels.brand_key) — Magnum's are its Mini pistachio, Almond,
--     Cone...;
--   * an UNBRANDED product's are the products whose name contains ALL of its words —
--     tiramisu's are tiramisu cupcake, matcha tiramisu...
-- "Related", not "variant": the word rule also catches dishes that use the product
-- ("fish sauce chicken wings" under fish sauce). It is an evidence list for a reader,
-- not a hierarchy anything is counted against — every product still ranks on its own.
--
-- Posts are counted over the social_trend_variant_window_weeks calendar weeks ending at
-- the row's week (the fade's 3-4 week horizon), each post once per product.

with board_products as (

    select distinct week_start, concept_class, concept_norm
    from {{ ref('int_social_trend_board') }}
    where is_on_board

),

labels as (

    select product_key, product_type, brand_key
    from {{ ref('int_social_product_labels') }}

),

products as (

    select product_key, max(product_name) as product_name
    from {{ ref('int_social_concept_canon') }}
    group by 1

),

-- posts per product per week, each post once
product_week_posts as (

    select
        c.product_key,
        cast(f.posted_week as date)                                     as week_start,
        count(distinct m.mention_id)                                    as posts
    from {{ ref('int_social_concept_mentions') }} as m
    inner join {{ ref('int_social_concept_canon') }} as c
        on  c.concept_class = m.concept_class
        and c.concept_norm  = m.concept_norm
    inner join {{ ref('fct_social_mentions') }} as f
        on f.mention_id = m.mention_id
    group by 1, 2

),

-- word rows, for the unbranded "name contains all my words" rule
product_words as (

    select product_key, {{ unnest(split_words('product_key')) }} as word
    from products

),

parent_words as (

    select distinct b.concept_norm as parent_key, w.word
    from (select distinct concept_norm from board_products) as b
    inner join product_words as w
        on w.product_key = b.concept_norm
    where nullif(trim(w.word), '') is not null

),

parent_word_counts as (

    select parent_key, count(*) as n_words
    from parent_words
    group by 1

),

by_words as (

    select pw.parent_key, w.product_key as related_key
    from parent_words as pw
    inner join parent_word_counts as c
        on c.parent_key = pw.parent_key
    inner join product_words as w
        on w.word = pw.word and w.product_key <> pw.parent_key
    group by pw.parent_key, w.product_key
    having count(distinct w.word) = max(c.n_words)

),

by_brand as (

    select b.concept_norm as parent_key, l2.product_key as related_key
    from (select distinct concept_norm from board_products) as b
    inner join labels as l1
        on l1.product_key = b.concept_norm
    inner join labels as l2
        on  l2.brand_key = l1.brand_key
        and l2.product_key <> l1.product_key
    where l1.product_type = 'branded' and l1.brand_key is not null

),

relations as (

    -- branded products relate by brand; unbranded ones by name words
    select r.parent_key, r.related_key
    from by_brand as r
    union
    select w.parent_key, w.related_key
    from by_words as w
    left join labels as l
        on l.product_key = w.parent_key
    where coalesce(l.product_type, 'generic') <> 'branded'

),

windowed as (

    select
        bp.week_start,
        bp.concept_class,
        bp.concept_norm,
        r.related_key,
        sum(pw.posts)                                                   as recent_posts
    from board_products as bp
    inner join relations as r
        on r.parent_key = bp.concept_norm
    inner join product_week_posts as pw
        on  pw.product_key = r.related_key
        and pw.week_start between cast({{ dbt.dateadd('day', -window_days, 'bp.week_start') }} as date)
                              and bp.week_start
    group by 1, 2, 3, 4

),

ranked as (

    select
        w.*,
        p.product_name                                                  as related_name,
        row_number() over (
            partition by w.week_start, w.concept_class, w.concept_norm
            order by w.recent_posts desc, w.related_key
        )                                                               as _rn
    from windowed as w
    left join products as p
        on p.product_key = w.related_key

)

select
    week_start,
    concept_class,
    concept_norm,
    count(*)                                                            as related_products,
    -- FILTER, not a CASE inside the aggregate: DuckDB's array_agg keeps NULLs while
    -- Databricks' drops them, so a CASE would pad the list on one engine only
    array_agg(concat(coalesce(related_name, related_key), ' (',
                     cast(recent_posts as {{ dbt.type_string() }}), ')'))
        filter (where _rn <= {{ var('social_trend_variant_count') }})  as top_variants
from ranked
group by 1, 2, 3
