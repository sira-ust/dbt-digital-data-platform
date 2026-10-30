{{ config(tags=['social']) }}
-- int_social_post_products — every post's tags mapped to the PRODUCT key the board
-- counts it under: one row per (mention, product, spelling).
--
-- MIRRORS int_social_concept_trends.grouped — the name map (int_social_concept_canon)
-- then the resolver's grouping (group_primary) — so a board row's posts here are the
-- posts the board counted. Keep the two in step: if the board's mapping changes, this
-- must change with it, or "12 of 25 posts" stops meaning the row's 25.
--
-- term is the spelling the post used (lower-cased), which is what tells the driver
-- line which words ARE the row (its own spellings are not what drives it).

with concept_groups as (

    select concept_norm, group_primary
    from {{ ref('stg_mentionlytics__concept_resolution') }}
    where group_primary is not null

)

select distinct
    cm.mention_id,
    cast(f.posted_week as date)                                         as week_start,
    coalesce(cn.product_class, cm.concept_class)                        as concept_class,
    coalesce(g.group_primary, cn.product_key, cm.concept_norm)          as concept_norm,
    lower(trim(cm.concept_text))                                        as term
from {{ ref('int_social_concept_mentions') }} as cm
inner join {{ ref('fct_social_mentions') }} as f
    on f.mention_id = cm.mention_id
left join {{ ref('int_social_concept_canon') }} as cn
    on  cn.concept_class = cm.concept_class
    and cn.concept_norm  = cm.concept_norm
left join concept_groups as g
    on g.concept_norm = coalesce(cn.product_key, cm.concept_norm)
