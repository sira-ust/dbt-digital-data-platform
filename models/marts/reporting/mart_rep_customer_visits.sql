{{ config(materialized='table') }}

-- NOT incremental by design: this is a lifetime aggregate at (rep, customer) grain
-- with no date partition — first_visit_at, last_visit_at, visit_days and the counts
-- span all history, so any new event can mutate an existing row. There's no clean
-- "new rows only" slice; full-refresh table is the correct choice.

with events as (

    select * from {{ ref('int_rep_activity_events') }}

),

customer_events as (

    -- exclude self-reference rows (rep checking in without a customer context)
    select *
    from events
    where customer is not null
      and customer != username

),

agg as (

    select
        username,
        sales_code,
        customer,
        count(*)                                                        as total_activity_events,
        count(distinct activity_date)                                   as visit_days,
        min(begin_time)                                                 as first_visit_at,
        max(begin_time)                                                 as last_visit_at,
        count(distinct sku)                                             as unique_skus_shown,
        count(case when sku is not null then 1 end)                     as sku_events,
        count(case when location is not null then 1 end)                as gps_events
    from customer_events
    group by 1, 2, 3

)

select
    username,
    sales_code,
    customer,
    total_activity_events,
    visit_days,
    first_visit_at,
    last_visit_at,
    {{ dbt.datediff('first_visit_at', 'last_visit_at', 'day') }}        as relationship_days,
    unique_skus_shown,
    sku_events,
    gps_events,
    case when gps_events > 0 then true else false end                   as has_gps
from agg
