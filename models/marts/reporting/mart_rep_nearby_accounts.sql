{{ config(materialized='table') }}

-- mart_rep_nearby_accounts — ONE ROW PER REP x ANCHOR ACCOUNT x NEARBY ACCOUNT
-- THAT NEEDS ATTENTION. "I'm at ABC Market — who else round here has gone
-- quiet?"
--
--   Anchor | Nearby account | Distance | Why it needs a call | Last ordered
--
-- THE WHOLE TABLE IS A "WHILE YOU'RE THERE" LIST. It deliberately does NOT
-- carry every neighbour — only the ones mart_rep_account_status has already
-- flagged as needing attention (attention_priority <= 2: no order on record,
-- or overdue). A complete neighbour list would be far larger and would make a
-- rep read past the healthy accounts to find the one worth a detour.
--
-- ANCHOR vs NEARBY. The anchor is where the rep IS (or is heading); nearby is
-- what they could add to the trip. Every one of the rep's accounts gets to be
-- an anchor, because the assistant does not know today's route — it is asked
-- "who's near X" and looks X up. An account can appear as both an anchor and
-- somebody else's neighbour, which is correct, not double counting.
--
-- SCOPED TO ONE REP'S BOOK. Both sides come from mart_rep_account_status for
-- the SAME sales_code, so this never suggests calling on a colleague's
-- account. That table's spine is already the right definition of "the rep's
-- accounts" — owned in NAV, or sold to in fact.
--
-- ═══ WHAT THIS CANNOT SEE ══════════════════════════════════════════════════
-- BOTH ACCOUNTS NEED A COORDINATE, and 12% of customers have none. An account
-- with no resolvable address is ABSENT from this table entirely — as an anchor
-- and as a neighbour. Absent therefore means "not knowable", never "nothing
-- nearby", and an assistant must not say "there is nobody near you" on the
-- strength of an empty result. dim_customers.has_coordinates is where that
-- distinction lives; this model can only inherit it.
--
-- STRAIGHT-LINE DISTANCE, NOT DRIVING DISTANCE. haversine_metres is
-- great-circle: it ignores roads, water and one-way systems. Two stores 800 m
-- apart across a freeway with no crossing are 800 m here and fifteen minutes
-- apart in a van. Treat the radius as a shortlist, not an itinerary.
--
-- NO VISIT HISTORY IS USED. "Nearby" is geography and "needs attention" is the
-- ORDER clock, deliberately — mart_rep_account_status stays off visit data
-- because the geofence and idle-gap heuristics are not accurate enough to tell
-- a rep he has not called on someone, and this table inherits that discipline.
-- So a neighbour flagged here may well have been visited last week; what it
-- says is that they have not ORDERED.

{% set radius = var('rep_nearby_radius_metres') %}
{% set top_n  = var('rep_nearby_top_n') %}

with book as (

    select
        s.sales_code,
        s.rep_name,
        s.customer_key,
        s.customer_name,
        s.city,
        s.county,
        s.attention_reason,
        s.attention_priority,
        s.needs_attention,
        s.last_order_date,
        s.days_since_last_order,
        s.orders_recent,
        s.order_value_recent,
        s.delivery_days,
        s.delivery_day_count,
        s.appointment_required,
        s.customer_is_active,
        c.latitude,
        c.longitude
    from {{ ref('mart_rep_account_status') }} as s
    join {{ ref('dim_customers') }} as c
        on c.customer_key = s.customer_key
    -- both sides of the pairing need a coordinate; see the header on why an
    -- absent account is "not knowable" rather than "nothing nearby"
    where c.has_coordinates
      and c.latitude  is not null
      and c.longitude is not null

),

-- Every account the rep has, as a place to be standing.
anchors as (

    select
        sales_code, rep_name, customer_key, customer_name, city, county,
        latitude, longitude
    from book

),

-- Only the ones worth a detour. attention_priority 1 = never ordered,
-- 2 = overdue; 5 is healthy and 9 is an inactive account, and neither belongs
-- on a "while you're there" list.
worth_a_call as (

    select * from book where attention_priority <= 2

),

paired as (

    select
        a.sales_code,
        a.rep_name,
        a.customer_key                                                   as anchor_customer_key,
        a.customer_name                                                  as anchor_customer_name,
        a.city                                                           as anchor_city,
        a.county                                                         as anchor_county,

        n.customer_key                                                   as nearby_customer_key,
        n.customer_name                                                  as nearby_customer_name,
        n.city                                                           as nearby_city,
        n.attention_reason,
        n.attention_priority,
        n.last_order_date,
        n.days_since_last_order,
        n.orders_recent,
        n.order_value_recent,
        n.delivery_days,
        n.delivery_day_count,
        n.appointment_required,
        n.customer_is_active,

        {{ haversine_metres('a.latitude', 'a.longitude',
                            'n.latitude', 'n.longitude') }}              as distance_metres
    from anchors      as a
    join worth_a_call as n
        on  n.sales_code   = a.sales_code
        and n.customer_key <> a.customer_key
        -- BOUNDING BOX FIRST. The haversine below is the real test, but
        -- evaluating it across a full self-join of a rep's book is what makes
        -- this expensive — see macros/time_convert.sql, where the same
        -- prefilter took a presence join from 27s to 7.8s. 110,000 m per
        -- degree of latitude and 85,000 per degree of longitude at 37N are
        -- deliberately generous, so the box never clips a true match.
        and abs(a.latitude  - n.latitude)  < {{ radius }} / 110000.0
        and abs(a.longitude - n.longitude) < {{ radius }} / 85000.0

),

ranked as (

    select
        p.*,
        row_number() over (
            partition by p.sales_code, p.anchor_customer_key
            -- most urgent first, then closest. Deliberately NOT closest-first:
            -- an account that has never ordered is worth 3 km more than one
            -- that is merely overdue is worth 300 m. customer_key breaks exact
            -- ties so the list is reproducible across runs and engines.
            order by p.attention_priority, p.distance_metres, p.nearby_customer_key
        )                                                                as nearby_rank
    from paired as p
    where p.distance_metres <= {{ radius }}

)

select
    sales_code,
    rep_name,

    -- ── where the rep is ──────────────────────────────────────────────────
    anchor_customer_key,
    anchor_customer_name,
    anchor_city,
    anchor_county,

    -- ── what else is worth a stop ─────────────────────────────────────────
    -- 1 = suggest this one first. Ordered by urgency THEN distance, so the
    -- list reads as "who most needs a call", not "who is closest".
    nearby_rank,
    nearby_customer_key,
    nearby_customer_name,
    nearby_city,

    -- STRAIGHT-LINE metres, not driving distance — see the header. Rounded to
    -- the metre; the underlying coordinates are geocoded addresses, so
    -- sub-metre precision would be false confidence.
    round(distance_metres)                                               as distance_metres,
    round(distance_metres / 1000.0, 2)                                   as distance_km,

    -- ── why it is on the list ─────────────────────────────────────────────
    -- Carried through from mart_rep_account_status unchanged, so the two
    -- tables can never disagree about why an account needs a call.
    attention_reason,
    attention_priority,
    last_order_date,
    -- NULL means nothing on record since the order feed began — NOT "never
    -- ordered in the history of the company", and not a large number either.
    days_since_last_order,
    orders_recent,
    order_value_recent,
    customer_is_active,

    -- ── when a call has to happen ─────────────────────────────────────────
    -- A neighbour that only takes Thursday deliveries is not worth a Friday
    -- detour. 0 delivery days means NAV has no pattern on file — unknown,
    -- not "never delivers".
    delivery_days,
    delivery_day_count,
    appointment_required
from ranked
where nearby_rank <= {{ top_n }}
