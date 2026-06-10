-- Item-level interactions (L1 families 10, 14, 15, 18):
--   10 page views (bare-value payload: page context)
--   14/15 cart + detail events (bare-value payload: SKU)
--   18 catalog interactions — barcode scans (18010000, kv payload) and
--      icon clicks (bare title payload)

with events as (

    select * from {{ ref('int_events_enriched') }}
    where l1_code in ('10', '14', '15', '18')

)

select
    entity_id,
    description_code,
    function_name,
    l1_code,
    is_success,
    is_failure,
    source_code,
    app_name,
    app_platform,
    actor_type,
    customer_key,
    sales_code,
    created_at_utc,
    event_at_utc,

    -- bare-value payloads, interpreted per family
    case when l1_code in ('14', '15') then nullif(trim(response), '') end as sku,
    case when l1_code = '10' then nullif(trim(response), '') end as page_context,
    case
        when l1_code = '18' and description_code <> '18010000'
            then nullif(trim(response), '')
    end as clicked_title,

    -- barcode scans (18010000) use the kv format
    case
        when description_code = '18010000'
            then {{ parse_kv_response('response', 'category') }}
    end as scan_category_id,

    response as response_raw

from events
