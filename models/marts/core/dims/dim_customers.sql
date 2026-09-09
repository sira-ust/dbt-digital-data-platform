-- dim_customers — one row per customer_key. The conformed customer dimension:
-- the name to say out loud, who owns the account, whether it is live, and
-- whether we could geofence it at all.
--
-- EVERY account is here, including inactive ones and ones with no coordinate.
-- That is the difference between this and stg_nav__customer_locations, and it
-- is the point: 12% of customers have no resolvable address, and for those
-- "no visit recorded" means NOT KNOWABLE, not "did not visit". has_coordinates
-- is how that distinction reaches a consumer instead of dying in an inner join.
--
-- WHY A CUSTOMER DIMENSION AT ALL: every rep mart to date carries customer_key
-- and nothing else, so a report reads "40 minutes at SUN015". That is
-- unusable in a spoken answer and barely usable in a written one. The name has
-- always been one join away in NAV; this makes it one join away from a mart.
--
-- customer_key here is the NAV/WMS code space (= mysql ust_customer_no =
-- jdawms stcust). The CUSTOMER-app side of the event log identifies people by
-- username instead, and those keys are NOT in this table — see
-- int_events_decoded for how the two spaces coexist in customer_key.

with customers as (

    select * from {{ ref('stg_nav__customers') }}

),

locations as (

    select
        customer_key,
        latitude,
        longitude,
        geocoded_address,
        geocoded_at
    from {{ ref('stg_nav__customer_locations') }}

),

reps as (

    select sales_code, rep_name from {{ ref('dim_reps') }}

)

select
    c.customer_key,
    c.customer_name,
    c.customer_name_2,

    c.address,
    c.city,
    c.county,
    c.post_code,
    c.country_region_code,

    -- who NAV says owns the account, and their display name. This is ownership,
    -- NOT "who last worked it" — a rep can legitimately transact on a
    -- colleague's account, and the activity marts record who actually did.
    c.salesperson_code                                                   as owner_rep,
    r.rep_name                                                           as owner_rep_name,

    c.is_active,

    -- THE HONESTY FLAG. False means this account could never have matched a GPS
    -- fix, so its visit history is unknown rather than empty. Any statement of
    -- the form "you have not called on X" must check this first.
    (l.customer_key is not null)                                         as has_coordinates,
    l.latitude,
    l.longitude,
    l.geocoded_address,
    l.geocoded_at,

    -- seeded junk and internal accounts, flagged rather than deleted so a
    -- consumer can see why a count differs from the raw customer master.
    -- int_rep_customer_presence drops these from the geofence outright.
    {{ is_test_customer('c.customer_key') }}                             as is_test_account,

    -- the delivery-day pattern. Seven booleans for filtering, plus one readable
    -- string for a spoken answer ("Tue, Thu"). concat_ws skips nulls on both
    -- engines, so an unchecked day contributes nothing rather than an empty slot.
    c.accepts_monday,
    c.accepts_tuesday,
    c.accepts_wednesday,
    c.accepts_thursday,
    c.accepts_friday,
    c.accepts_saturday,
    c.accepts_sunday,
    nullif(concat_ws(', ',
        case when c.accepts_monday    then 'Mon' end,
        case when c.accepts_tuesday   then 'Tue' end,
        case when c.accepts_wednesday then 'Wed' end,
        case when c.accepts_thursday  then 'Thu' end,
        case when c.accepts_friday    then 'Fri' end,
        case when c.accepts_saturday  then 'Sat' end,
        case when c.accepts_sunday    then 'Sun' end
    ), '')                                                               as delivery_days,
    -- 0 means NAV has no delivery pattern on file for this account, which is
    -- different from "delivers no day of the week" — treat it as unknown.
    (case when c.accepts_monday    then 1 else 0 end
     + case when c.accepts_tuesday   then 1 else 0 end
     + case when c.accepts_wednesday then 1 else 0 end
     + case when c.accepts_thursday  then 1 else 0 end
     + case when c.accepts_friday    then 1 else 0 end
     + case when c.accepts_saturday  then 1 else 0 end
     + case when c.accepts_sunday    then 1 else 0 end)                  as delivery_day_count,

    c.appointment_required,
    c.customer_group,
    c.customer_price_group,
    c.payment_terms_code,
    c.jda_route,
    c.m2_customer_id
from customers as c
left join locations as l on l.customer_key = c.customer_key
left join reps      as r on r.sales_code   = c.salesperson_code
