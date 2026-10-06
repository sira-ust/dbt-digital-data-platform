-- assert_social_merged_product_counts_each_post_once
--
-- After the canonical-product merge, a post counts AT MOST ONCE per product per week.
-- The merge maps several spellings — and both boards — onto one product BEFORE
-- int_social_concept_trends counts posts, precisely so that a post naming "ไอติมเลย์"
-- and "lays ice cream" is one post about lay's ice cream, not two. If the merge were
-- ever moved after the counting step (or concept_mentions' select distinct lost the
-- class), a product's mention_count would exceed the distinct posts naming any of its
-- spellings that week. This recounts those posts independently, from the cleaned names
-- and the canonical map, and compares.
--
-- Fails (returns a row) per product-week whose mention_count exceeds its distinct
-- posts. Severity: error.

-- both merge layers, in the model's order: name -> canonical product, then the
-- resolver's group_primary on top (it groups two PRODUCTS, e.g. matcha powder -> matcha)
with groups as (

    select concept_norm, group_primary
    from {{ ref('stg_mentionlytics__concept_resolution') }}
    where group_primary is not null

),

posts as (

    select
        cast(f.posted_week as date)                                   as week_start,
        coalesce(c.product_class, m.concept_class)                    as concept_class,
        coalesce(g.group_primary, c.product_key, m.concept_norm)      as product_key,
        count(distinct m.mention_id)                                  as distinct_posts
    from {{ ref('int_social_concept_mentions') }} as m
    inner join {{ ref('fct_social_mentions') }} as f
        on f.mention_id = m.mention_id
    left join {{ ref('int_social_concept_canon') }} as c
        on  c.concept_class = m.concept_class
        and c.concept_norm  = m.concept_norm
    left join groups as g
        on g.concept_norm = coalesce(c.product_key, m.concept_norm)
    group by 1, 2, 3

)

select t.week_start, t.concept_class, t.concept_norm, t.mention_count, p.distinct_posts
from {{ ref('int_social_concept_trends') }} as t
inner join posts as p
    on  p.week_start    = t.week_start
    and p.concept_class = t.concept_class
    and p.product_key   = t.concept_norm
where t.mention_count > p.distinct_posts
