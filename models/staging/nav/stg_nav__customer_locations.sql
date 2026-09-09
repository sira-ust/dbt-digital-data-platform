-- stg_nav__customer_locations — one row per customer with a usable coordinate.
--
-- Joins the customer master (stg_nav__customers) to
-- ust_external.nav_customer_geocode (the coordinate resolved from its address
-- by scripts/geocode_customers.py).
--
-- WHY THE GEOCODE IS NOT IN navrep: that schema is a read-only replication
-- target owned by the ingestion process. A hand-written table there could be
-- dropped by a schema sync with nothing to restore it, and would read as though
-- it were part of the NAV feed. ust_external says it is ours and produced
-- out-of-band; the nav_ prefix records what it was derived from.
--
-- The customer columns come from stg_nav__customers rather than being re-cast
-- from the source here, so the two models can never disagree about a name or
-- about the in_active polarity flip. This model's ONLY job is the geocode join
-- and the coordinate quality filter.
--
-- Rows WITHOUT a usable coordinate are excluded rather than carried as nulls:
-- a customer with no location cannot be geofenced at all, and downstream that
-- has to read as "unknown", never as "did not visit". Excluding them makes it a
-- left-join miss, which is the honest shape. Consumers that need EVERY account
-- (the rep's own book, for instance) must read stg_nav__customers or
-- dim_customers, which carries has_coordinates for exactly this reason.

with customer as (

    select * from {{ ref('stg_nav__customers') }}

),

geocode as (

    select * from {{ source('ust_external', 'nav_customer_geocode') }}

)

select
    c.customer_key,
    c.customer_name,

    cast(g.latitude  as double)                                          as latitude,
    cast(g.longitude as double)                                          as longitude,

    c.address,
    c.city,
    c.county,
    c.post_code,

    c.salesperson_code,

    -- flipped once, in stg_nav__customers. 3,485 of 7,198 customers (48%) are
    -- inactive and every one of them was a live geofence candidate: 975 of
    -- 8,048 recorded visits and 31,948 on-site minutes were credited to dead
    -- accounts. Excluding them from the candidate set is NOT safe (a rep can
    -- visit a lapsed customer), so this is carried as a column and used as a
    -- tie-break in int_rep_customer_presence instead.
    c.is_active,

    -- provenance: which string was actually resolved, and when
    g.geocoded_address,
    g.geocoded_at
from customer as c
inner join geocode as g
    -- trimmed on BOTH sides: customer_key is already trimmed in
    -- stg_nav__customers, so comparing it to a raw geocode key would miss any
    -- row the geocoder wrote with padding.
    on nullif(trim(cast(g.customer_no as {{ dbt.type_string() }})), '') = c.customer_key
where g.latitude  is not null
  and g.longitude is not null
  -- (0,0) is the classic geocoder failure — it is in the Gulf of Guinea, not a
  -- customer, and would silently match any fix that also failed to (0,0)
  and not (g.latitude = 0 and g.longitude = 0)
