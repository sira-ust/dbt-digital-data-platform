-- The AI judge's ruling on each (promo item, mention) keyword candidate. One row
-- per (item_no, mention_id): the latest judgment at the CURRENT judge version wins
-- over older versions, so bumping JUDGE_PROMPT_VERSION re-judges without a truncate.

with source as (

    select * from {{ source('promo', 'social_judgments') }}

),

typed as (

    select
        nullif(trim(cast(item_no as {{ dbt.type_string() }})), '')               as item_no,
        try_cast(mention_id as bigint)                                            as mention_id,
        nullif(trim(cast(keyword_level as {{ dbt.type_string() }})), '')         as keyword_level,
        nullif(cast(brand_hit as {{ dbt.type_string() }}), '')                   as brand_hit,
        nullif(cast(product_hit as {{ dbt.type_string() }}), '')                 as product_hit,
        nullif(cast(flavor_hit as {{ dbt.type_string() }}), '')                  as flavor_hit,
        cast(match_text as {{ dbt.type_string() }})                              as match_text,
        lower(trim(cast(verdict as {{ dbt.type_string() }})))                    as verdict,
        nullif(trim(cast(judge_votes as {{ dbt.type_string() }})), '')           as judge_votes,
        nullif(trim(cast(matched_content_item as {{ dbt.type_string() }})), '')  as matched_content_item,
        nullif(trim(cast(reason as {{ dbt.type_string() }})), '')                as reason,
        nullif(trim(cast(judge_model as {{ dbt.type_string() }})), '')           as judge_model,
        nullif(trim(cast(judge_version as {{ dbt.type_string() }})), '')         as judge_version,
        try_cast(judged_at as timestamp)                                          as judged_at
    from source

),

numbered as (

    select
        *,
        row_number() over (
            partition by item_no, mention_id
            order by judge_version desc, judged_at desc
        ) as _rn
    from typed
    where item_no is not null and mention_id is not null

)

select
    item_no, mention_id, keyword_level, brand_hit, product_hit, flavor_hit, match_text,
    verdict, judge_votes, matched_content_item, reason, judge_model, judge_version, judged_at
from numbered
where _rn = 1
