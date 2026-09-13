-- 'visit only, no app' means exactly that: the rep was inside the geofence and
-- the app recorded nothing for that customer. Such a row therefore has no app
-- evidence to settle WHICH customer he was in, and resolved_by_app must be
-- false — otherwise the ambiguity flag would be cleared on the one scenario
-- that can never earn it, and rep 030's Clement St cluster would read as
-- confidently attributed when distance is all we have.
--
-- The invariant holds today because resolved_by_app looks for an 'on-site' row
-- on the same customer-day, and a customer-day carrying an 'on-site' row cannot
-- also produce a 'visit only, no app' row: the visit_only branch only fires
-- where by_scenario found nothing at all. This test exists so that widening the
-- resolution rule later cannot silently break that.

select
    customer_day_key,
    sales_code,
    customer_key,
    activity_date,
    scenario,
    resolved_by_app,
    geofence_ambiguous,
    is_ambiguous
from {{ ref('mart_rep_customer_activity') }}
where scenario = 'visit only, no app'
  and resolved_by_app
