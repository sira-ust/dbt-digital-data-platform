-- Lossless staging for the LLM enrichment. One row per mention_id (latest
-- enriched_at wins — the enrichment table is append-only, so a re-enrichment of
-- the same mention is deduped here). Light work only: cast + dedupe. The
-- multi-label array columns pass through unchanged.

with source as (

    select * from {{ source('mentionlytics', 'mention_enrichment') }}

),

typed as (

    select
        cast(mention_id as bigint)                                              as mention_id,
        cast(is_food_relevant as boolean)                                       as is_food_relevant,
        cast(is_spam as boolean)                                                as is_spam,
        themes,
        mentioned_dishes,
        ingredients,
        brands,
        nullif(trim(cast(sentiment_normalized as {{ dbt.type_string() }})), '') as sentiment_normalized,
        cast(confidence as double)                                              as confidence,
        cast(enriched_at as timestamp)                                          as enriched_at,
        nullif(trim(cast(model_version as {{ dbt.type_string() }})), '')        as model_version
    from source

),

numbered as (

    select *,
        row_number() over (partition by mention_id order by enriched_at desc) as _rn
    from typed

)

select
    mention_id,
    is_food_relevant,
    is_spam,
    themes,
    mentioned_dishes,
    ingredients,
    brands,
    sentiment_normalized,
    confidence,
    enriched_at,
    model_version
from numbered
where _rn = 1
