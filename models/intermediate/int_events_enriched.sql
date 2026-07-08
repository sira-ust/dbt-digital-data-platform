-- All events enriched with the event dictionary (seed_event_codes) and the
-- app-source registry. Event grain — one row per log record.
--
-- Reads the decoded spine (int_events_decoded); decoding/parsing lives there,
-- this model only adds the dictionary + app-source joins and the dictionary-
-- driven classification columns:
--   outcome        success/fail parsed from the dev team's "- Success/- Fail"
--                  function names (the flip segment differs by family, so the
--                  name is the authoritative marker, not the code position)
--   feature_name   canonical product feature (search, filter, icon_click, ...)
--   feature_group  rollup: discovery / navigation / cart / stock
--   page_context   which catalog section the action happened in
--                  (promo / backorder / history / suggest)
--   is_add / is_remove / is_qty_change   cart-edit flags (10.05x/10.04x/10.15x)
--
-- All classification applies ONLY to dictionary-mapped codes: unmapped codes
-- (legacy app codes, scanner junk) get nulls and are surfaced separately in
-- dq_unmapped_event_codes. Aggregations belong in mart_* (not in intermediate).

with events as (

    select * from {{ ref('int_events_decoded') }}

),

codes as (

    select * from {{ ref('seed_event_codes') }}

),

apps as (

    select * from {{ ref('seed_app_sources') }}

)

select
    e.*,
    c.function_name,
    c.l1_category_name,
    c.payload_format as expected_payload_format,
    c.has_geo as expects_geo,
    c.is_system_event,
    c.event_type,
    c.log_level,
    a.app_name,
    a.user_type as app_user_type,
    a.platform as app_platform,

    -- ── outcome: parsed from the dictionary name, mapped codes only ─────
    case
        when c.description_code is null then null
        when lower(c.function_name) like '%fail%'    then 'fail'
        when lower(c.function_name) like '%success%' then 'success'
    end                                                                 as outcome,

    -- ── cart-edit flags (order-ops family, positions 1-4) ───────────────
    (c.description_code is not null
        and substr(e.description_code, 1, 4) = '1005')                  as is_add,
    (c.description_code is not null
        and substr(e.description_code, 1, 4) = '1004')                  as is_remove,
    (c.description_code is not null
        and substr(e.description_code, 1, 4) = '1015')                  as is_qty_change,

    -- ── feature: the action type. OOS check is name-based (lives in two
    --    families); the rest map from the L1 family. icon_click is only the
    --    18-family codes that are actual icon taps. ──────────────────────
    case
        when c.description_code is null then null
        when lower(c.function_name) like '%oos%'     then 'oos_check'
        when e.l1_code = '12'                        then 'search'
        when e.l1_code = '11'                        then 'filter'
        when e.l1_code = '19'                        then 'catalog_view'
        when e.l1_code = '14'                        then 'item_detail'
        when e.l1_code = '15'                        then 'image_enlarge'
        when e.l1_code = '18'
            and lower(c.function_name) like '%icon%' then 'icon_click'
    end                                                                 as feature_name,

    -- ── page context: which catalog section, independent of the action.
    --    add_item_promo_page = cart add (flag) in the promo section. ─────
    case
        when c.description_code is null then null
        when lower(c.function_name) like '%backorder%' then 'backorder'
        when lower(c.function_name) like '%history%'   then 'history'
        when lower(c.function_name) like '%suggest%'   then 'suggest'
        when lower(c.function_name) like '%promo%'     then 'promo'
    end                                                                 as page_context,

    -- ── feature rollup ───────────────────────────────────────────────────
    case
        when c.description_code is null then null
        when substr(e.description_code, 1, 4) in ('1004', '1005', '1015')
            then 'cart'
        when lower(c.function_name) like '%oos%'
            then 'stock'
        when e.l1_code in ('11', '12', '19')
            or (e.l1_code = '18' and lower(c.function_name) like '%icon%')
            then 'discovery'
        when e.l1_code in ('14', '15')
            then 'navigation'
    end                                                                 as feature_group

from events as e
left join codes as c
    on e.description_code = c.description_code
left join apps as a
    on e.source_code = a.source_code
