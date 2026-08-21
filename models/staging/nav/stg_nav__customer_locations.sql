-- stg_nav__customer_locations — one row per customer with a usable coordinate.
--
-- Joins the NAV customer master (the address) to
-- ust_external.nav_customer_geocode (the coordinate resolved from it by
-- scripts/geocode_customers.py).
--
-- WHY THE GEOCODE IS NOT IN navrep: that schema is a read-only replication
-- target owned by the ingestion process. A hand-written table there could be
-- dropped by a schema sync with nothing to restore it, and would read as though
-- it were part of the NAV feed. ust_external says it is ours and produced
-- out-of-band; the nav_ prefix records what it was derived from.
--
-- customer_no is the same code as mysql ust_customer_no and jdawms stcust
-- (confirmed exact, no normalisation) — so it joins straight to customer_key.
--
-- Rows WITHOUT a usable coordinate are excluded rather than carried as nulls:
-- a customer with no location cannot be geofenced at all, and downstream that
-- has to read as "unknown", never as "did not visit". Excluding them makes it a
-- left-join miss, which is the honest shape.

with customer as (

    select * from {{ source('nav', 'customer') }}

),

geocode as (

    select * from {{ source('ust_external', 'nav_customer_geocode') }}

)

select
    nullif(trim(cast(c.customer_no as {{ dbt.type_string() }})), '')     as customer_key,
    nullif(trim(cast(c.name        as {{ dbt.type_string() }})), '')     as customer_name,

    cast(g.latitude  as double)                                          as latitude,
    cast(g.longitude as double)                                          as longitude,

    nullif(trim(cast(c.address   as {{ dbt.type_string() }})), '')       as address,
    nullif(trim(cast(c.city      as {{ dbt.type_string() }})), '')       as city,
    nullif(trim(cast(c.county    as {{ dbt.type_string() }})), '')       as county,
    nullif(trim(cast(c.post_code as {{ dbt.type_string() }})), '')       as post_code,

    nullif(trim(cast(c.salesperson_code as {{ dbt.type_string() }})), '') as salesperson_code,

    -- NAV stores this as in_active (1 = inactive), which reads backwards in a
    -- filter, so it is flipped once here. 3,485 of 7,198 customers (48%) are
    -- inactive and every one of them was a live geofence candidate: 975 of 8,048
    -- recorded visits and 31,948 on-site minutes were credited to dead accounts.
    -- Excluding them from the candidate set is NOT safe (a rep can visit a
    -- lapsed customer), so this is carried as a column and used as a tie-break
    -- in int_rep_customer_presence instead.
    (coalesce(cast(c.in_active as {{ dbt.type_int() }}), 0) = 0)          as is_active,

    -- provenance: which string was actually resolved, and when
    g.geocoded_address,
    g.geocoded_at
from customer as c
inner join geocode as g
    on g.customer_no = c.customer_no
where c.customer_no is not null
  and g.latitude    is not null
  and g.longitude   is not null
  -- (0,0) is the classic geocoder failure — it is in the Gulf of Guinea, not a
  -- customer, and would silently match any fix that also failed to (0,0)
  and not (g.latitude = 0 and g.longitude = 0)
