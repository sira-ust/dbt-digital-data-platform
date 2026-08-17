-- stg_nav__customer_locations — one row per customer with a usable coordinate.
--
-- Isolates the ONE thing int_rep_customer_presence needs from NAV: where each
-- customer physically is. Kept as its own staging model rather than reading
-- nav.customer directly, so that if the geocoding later moves to a different
-- table (a dedicated lookup, a vendor feed) only this file changes.
--
-- customer_no is the same code as mysql ust_customer_no and jdawms stcust
-- (confirmed exact, no normalisation) — so it joins straight to customer_key.
--
-- Rows without coordinates are EXCLUDED here rather than carried as nulls: a
-- customer with no location cannot be geofenced at all, and downstream that has
-- to read as "unknown", never as "did not visit". Keeping them out of this
-- model makes that a left-join miss, which is the honest shape.

with src as (

    select * from {{ source('nav', 'customer') }}

)

select
    nullif(trim(cast(customer_no as {{ dbt.type_string() }})), '')       as customer_key,
    nullif(trim(cast(name        as {{ dbt.type_string() }})), '')       as customer_name,

    cast(latitude  as double)                                            as latitude,
    cast(longitude as double)                                            as longitude,

    nullif(trim(cast(address   as {{ dbt.type_string() }})), '')         as address,
    nullif(trim(cast(city      as {{ dbt.type_string() }})), '')         as city,
    nullif(trim(cast(county    as {{ dbt.type_string() }})), '')         as county,
    nullif(trim(cast(post_code as {{ dbt.type_string() }})), '')         as post_code,

    nullif(trim(cast(salesperson_code as {{ dbt.type_string() }})), '')  as salesperson_code
from src
where customer_no is not null
  and latitude    is not null
  and longitude   is not null
  -- (0,0) is the classic geocoder failure — it is in the Gulf of Guinea, not a
  -- customer, and would silently match any fix that also failed to (0,0)
  and not (latitude = 0 and longitude = 0)
