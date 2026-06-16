-- int_feature_funnel — behaviour-level feature funnel for discovery analytics.
-- Links a home-page feature icon click (Group 18) to an add from that same
-- feature's page (Group 10.5), per customer per feature. There is no session
-- container in the event log, so this is a behaviour-level funnel (did a
-- customer who clicked feature X also add from page X?), not a strict
-- within-session sequence. Grain: customer_key x feature.

with events as (

    select * from {{ ref('int_events_enriched') }}

),

classified as (

    select
        customer_key,
        case description_code
            when '18040000' then 'Recommend'   -- click_suggest_icon
            when '18060000' then 'Promo'        -- click_promo_icon
            when '18050000' then 'New'          -- click_new_icon
            when '18020000' then 'Backorder'    -- click_backorder_icon
            when '10050200' then 'Recommend'    -- add_item_suggest_page
            when '10050300' then 'Promo'        -- add_item_promo_page
            when '10050500' then 'New'          -- add_item_new_page
            when '10050400' then 'Backorder'    -- add_item_backorder_page
        end                                                     as feature,
        case
            when l1_code = '18' then 'click'
            else 'add'
        end                                                     as funnel_step
    from events
    where description_code in (
        '18040000', '18060000', '18050000', '18020000',
        '10050200', '10050300', '10050500', '10050400'
    )

)

select
    customer_key,
    feature,
    count(*) filter (where funnel_step = 'click')               as click_events,
    count(*) filter (where funnel_step = 'add')                 as add_events
from classified
where feature is not null
  and customer_key is not null
group by
    customer_key,
    feature
