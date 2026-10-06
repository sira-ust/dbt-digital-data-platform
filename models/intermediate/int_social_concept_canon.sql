{{ config(tags=['social']) }}
-- int_social_concept_canon — the name -> PRODUCT map, one row per (concept_class,
-- concept_norm). Every spelling, script and board a thing was named under resolves to
-- ONE product with ONE name and ONE board:
--     "ไอติมเลย์" [item], "lays ice cream" [dish], "lay's ice cream" [item]
--         -> product_key 'lays ice cream', product_name "lay's ice cream", item
--
-- The LLM (scripts/canonicalize_concepts.py) only names each spelling's product and
-- votes item/dish for it. Everything that has to be CONSISTENT is decided here,
-- deterministically, across all of a product's spellings at once:
--   * product_key   the merge key: the LLM's name with apostrophes and hyphens
--                   removed, then folded by fold_concept — so "lay's" / "lays" and
--                   "salted-egg" / "salted egg" cannot split one product in two;
--   * product_class item or dish, by the product's spellings' votes WEIGHTED BY THEIR
--                   POSTS, not by which spelling happens to be first. A tie goes to
--                   item: a thing someone can buy is the side a distributor acts on;
--   * product_name  the display name: the LLM spelling carried by the most posts.
--
-- Coverage = whatever the script has canonicalised. A name it has not reached yet has
-- no row here; int_social_concept_trends falls back to the name itself, so a backlog
-- degrades to today's unmerged board rather than dropping anything.

with canon as (

    select * from {{ ref('stg_mentionlytics__concept_canon') }}

),

name_posts as (

    select concept_class, concept_norm, count(distinct mention_id) as name_mentions
    from {{ ref('int_social_concept_mentions') }}
    group by 1, 2

),

names_keyed as (

    select
        c.concept_class,
        c.concept_norm,
        c.canonical_name,
        c.canonical_class,
        {{ fold_concept("replace(replace(replace(c.canonical_name, '''', ''), '’', ''), '-', ' ')") }}
                                                                        as name_key,
        coalesce(p.name_mentions, 0)                                    as name_mentions
    from canon as c
    left join name_posts as p
        on  p.concept_class = c.concept_class
        and p.concept_norm  = c.concept_norm

),

-- SAME WORDS, ANY ORDER = ONE PRODUCT. The LLM named one 7-Eleven cake "lemon jelly
-- sponge cake", "lemon sponge jelly cake" and "sponge lemon jelly cake" in different
-- batches (measured 2026-10-06), so the merge key is the name's words SORTED. The
-- product keeps the key of its most-posted spelling, not the sorted string: almost
-- every product's key is unchanged by this, so labels keyed on it
-- (stg_mentionlytics__product_profile) still attach.
merge_groups as (

    select
        {{ sort_words('name_key') }}                                    as merge_key,
        name_key,
        sum(name_mentions)                                              as key_mentions
    from names_keyed
    group by 1, 2

),

representatives as (

    select merge_key, name_key as product_key
    from (
        select
            merge_key,
            name_key,
            row_number() over (
                partition by merge_key order by key_mentions desc, name_key
            )                                                           as _rn
        from merge_groups
    ) as r
    where _rn = 1

),

names as (

    select
        n.concept_class,
        n.concept_norm,
        n.canonical_name,
        n.canonical_class,
        r.product_key,
        n.name_mentions
    from names_keyed as n
    inner join merge_groups as g
        on g.name_key = n.name_key
    inner join representatives as r
        on r.merge_key = g.merge_key

),

class_votes as (

    select
        product_key,
        canonical_class,
        row_number() over (
            partition by product_key
            order by sum(name_mentions) desc,
                     case when canonical_class = 'item' then 0 else 1 end
        )                                                               as _rn
    from names
    where canonical_class in ('item', 'dish')
    group by product_key, canonical_class

),

display_names as (

    select
        product_key,
        canonical_name,
        row_number() over (
            partition by product_key
            order by sum(name_mentions) desc, canonical_name
        )                                                               as _rn
    from names
    group by product_key, canonical_name

),

product_size as (

    select product_key, count(*) as product_spellings, sum(name_mentions) as product_mentions
    from names
    group by 1

)

select
    n.concept_class,
    n.concept_norm,
    n.product_key,
    d.canonical_name                                                    as product_name,
    coalesce(v.canonical_class, n.concept_class)                        as product_class,
    n.canonical_class                                                   as name_class_vote,
    n.name_mentions,
    s.product_spellings,
    s.product_mentions
from names as n
left join class_votes as v
    on v.product_key = n.product_key and v._rn = 1
left join display_names as d
    on d.product_key = n.product_key and d._rn = 1
left join product_size as s
    on s.product_key = n.product_key
