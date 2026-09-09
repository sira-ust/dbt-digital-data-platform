-- stg_nav__customers — the NAV customer master, one row per customer_no.
-- 1:1 with navrep.customer: cast, trim, and flip the two backwards booleans.
-- No geocode join and NO filtering, deliberately — this is the complete account
-- book, including customers with no coordinate and inactive ones.
--
-- WHY THIS EXISTS SEPARATELY FROM stg_nav__customer_locations: that model INNER
-- JOINS the geocode table and drops anything unresolvable, which is right for
-- geofencing (a customer with no location cannot be matched to a GPS fix) and
-- wrong for everything else. 12% of customers have no coordinates; asking
-- "which of my accounts have I not called on" against the geofenced set would
-- silently omit them, and "no visit recorded" would read as "not visited" when
-- the truth is "not knowable". dim_customers carries has_coordinates so the
-- distinction survives to the consumer. customer_locations now reads its
-- customer columns from HERE, so the two can never disagree about a name or an
-- active flag.
--
-- customer_no is the same code as mysql ust_customer_no and jdawms stcust
-- (confirmed exact, no normalisation) — so it joins straight to customer_key.
--
-- No dedupe: customer_no is the source PK and the pipeline is a full load that
-- keeps only the latest runDate. The `unique` test on customer_key is the guard
-- rather than a silent row_number() that would hide a real ingestion fault.

with source as (

    select * from {{ source('nav', 'customer') }}

)

select
    nullif(trim(cast(customer_no as {{ dbt.type_string() }})), '')        as customer_key,
    nullif(trim(cast(name        as {{ dbt.type_string() }})), '')        as customer_name,
    nullif(trim(cast(name_2      as {{ dbt.type_string() }})), '')        as customer_name_2,

    nullif(trim(cast(address             as {{ dbt.type_string() }})), '') as address,
    nullif(trim(cast(city                as {{ dbt.type_string() }})), '') as city,
    nullif(trim(cast(county              as {{ dbt.type_string() }})), '') as county,
    nullif(trim(cast(post_code           as {{ dbt.type_string() }})), '') as post_code,
    nullif(trim(cast(country_region_code as {{ dbt.type_string() }})), '') as country_region_code,

    -- the rep NAV says owns the account. Joins to mysql
    -- admin_users.salesperson_code, which is the same code space as the
    -- sales_code carried on every event.
    nullif(trim(cast(salesperson_code as {{ dbt.type_string() }})), '')   as salesperson_code,

    -- NAV stores this as in_active (1 = inactive), which reads backwards in a
    -- filter, so it is flipped once — here, and only here. 3,485 of 7,198
    -- customers (48%) are inactive. Inactive does NOT mean "never contact":
    -- a rep can legitimately call on a lapsed account, so this is a column to
    -- read, never a filter to apply upstream of the consumer.
    (coalesce(cast(in_active as {{ dbt.type_int() }}), 0) = 0)            as is_active,

    -- the delivery-day pattern, as seven booleans. Load-bearing for the rep
    -- to-do list: an account that only takes Tuesday deliveries has to be
    -- ordered before Tuesday, so "who should I call today" depends on it.
    (coalesce(cast(monday_deliveries    as {{ dbt.type_int() }}), 0) = 1)  as accepts_monday,
    (coalesce(cast(tuesday_deliveries   as {{ dbt.type_int() }}), 0) = 1)  as accepts_tuesday,
    (coalesce(cast(wednesday_deliveries as {{ dbt.type_int() }}), 0) = 1)  as accepts_wednesday,
    (coalesce(cast(thursday_deliveries  as {{ dbt.type_int() }}), 0) = 1)  as accepts_thursday,
    (coalesce(cast(friday_deliveries    as {{ dbt.type_int() }}), 0) = 1)  as accepts_friday,
    (coalesce(cast(saturday_deliveries  as {{ dbt.type_int() }}), 0) = 1)  as accepts_saturday,
    (coalesce(cast(sunday_deliveries    as {{ dbt.type_int() }}), 0) = 1)  as accepts_sunday,

    -- appointment_required shares in_active's polarity problem only in that it
    -- is stored 0/1; 1 genuinely means "yes, an appointment is needed".
    (coalesce(cast(appointment_required as {{ dbt.type_int() }}), 0) = 1)  as appointment_required,

    nullif(trim(cast(customer_group        as {{ dbt.type_string() }})), '') as customer_group,
    nullif(trim(cast(customer_price_group  as {{ dbt.type_string() }})), '') as customer_price_group,
    nullif(trim(cast(payment_terms_code    as {{ dbt.type_string() }})), '') as payment_terms_code,
    nullif(trim(cast(responsibility_center as {{ dbt.type_string() }})), '') as responsibility_center,
    nullif(trim(cast(jda_route             as {{ dbt.type_string() }})), '') as jda_route,

    -- the Magento bridge. Carried, not used yet: the customer-app side of the
    -- event log identifies customers by username, not by this id.
    cast(m2_customer_id as bigint)                                        as m2_customer_id,

    cast(loaddate as timestamp)                                           as loaded_at
from source
where customer_no is not null
