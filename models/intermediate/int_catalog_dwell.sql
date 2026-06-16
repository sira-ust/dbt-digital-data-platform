-- int_catalog_dwell — Catalog View analytics (19010000) parsed to one row per
-- view event, with the kv payload (category, visits_num, time) decoded and the
-- category id resolved to a name via seed_categories. This is the only event
-- family that records actual time-on-page. Geo is available on these events.
-- Applies to CatalogFS / CatalogFC. Grain: one row per catalog-view event.

with views as (

    select * from {{ ref('int_events_enriched') }}
    where description_code = '19010000'

),

categories as (

    select * from {{ ref('seed_categories') }}

)

select
    v.entity_id,
    v.customer_key,
    v.source_code,
    v.app_name,
    v.app_platform,
    v.event_at_utc,
    {{ parse_kv_response('v.response', 'category') }}                  as category_id,
    c.category_name,
    try_cast({{ parse_kv_response('v.response', 'visits_num') }} as integer) as pages_viewed,
    try_cast({{ parse_kv_response('v.response', 'time') }} as integer)  as dwell_seconds,
    v.latitude,
    v.longitude
from views as v
left join categories as c
    on {{ parse_kv_response('v.response', 'category') }} = c.category_id
