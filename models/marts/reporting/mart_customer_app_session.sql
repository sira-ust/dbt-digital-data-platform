with sessions as (

    select * from {{ ref('int_customer_sessions') }}

),

agg as (

    select
        session_id,
        customer_id,
        customer_name,
        device_model,
        app_version,
        session_start,
        session_end,
        total_events,
        {{ dbt.datediff('session_start', 'session_end', 'minute') }} as session_minutes,
        count(event_id)                                              as events_recorded,
        count(distinct page)                                         as distinct_pages,
        count(case when page is not null then 1 end)                 as page_views,
        sum(duration_seconds)                                        as total_dwell_seconds,
        count(case when event_type like '%add%' then 1 end)          as add_events,
        count(
            case when event_type like '%delete%'
                   or event_type like '%remove%' then 1 end
        )                                                            as remove_events,
        count(
            case when event_type = 'submit_quote_cart_page' then 1 end
        )                                                            as submit_events,
        count(case when keyword is not null then 1 end)              as search_events,
        count(distinct sku)                                          as distinct_skus_interacted
    from sessions
    group by 1, 2, 3, 4, 5, 6, 7, 8

)

select
    session_id,
    customer_id,
    customer_name,
    device_model,
    app_version,
    session_start,
    session_end,
    session_minutes,
    total_events,
    events_recorded,
    distinct_pages,
    page_views,
    total_dwell_seconds,
    add_events,
    remove_events,
    submit_events,
    search_events,
    distinct_skus_interacted,
    case when submit_events > 0 then true else false end             as placed_order
from agg
