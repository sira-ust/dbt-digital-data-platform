-- Catalog View events (19010000). Payload: kv CSV —
--   category:8888,visits_num:2,time:15
-- Joined to seed_categories for category names (8888=Promo, 9999=Recommend, ...).

with events as (

    select * from {{ ref('int_events_enriched') }}
    where description_code = '19010000'

),

parsed as (

    select
        entity_id,
        source_code,
        app_name,
        app_platform,
        actor_type,
        customer_key,
        sales_code,
        latitude,
        longitude,
        created_at_utc,
        event_at_utc,

        {{ parse_kv_response('response', 'category') }} as category_id,
        try_cast({{ parse_kv_response('response', 'visits_num') }} as integer) as visits_num,
        try_cast({{ parse_kv_response('response', 'time') }} as integer) as time_s

    from events

)

select
    p.*,
    c.category_name

from parsed as p
left join {{ ref('seed_categories') }} as c
    on p.category_id = c.category_id
