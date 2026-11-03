{{ config(severity = 'error', warn_if = '>0', error_if = '>500') }}

-- Regression guard for the NULL sales_code drop (found 2026-10-30).
--
-- int_events_enriched removes exactly three things on purpose: sales code '000',
-- a system account, and an event with no timestamp. It used to spell the first
-- as `sales_code not in ('000')`, and NULL not in (...) is NULL, so every event
-- with NO sales code went with it. That is all of Vegas-I -- the iOS customer
-- app never sends one -- 10,345 deduped events in the week to 2026-10-28, gone
-- from fct_events, mart_customer_weekly and everything else built on the spine.
-- Nothing failed; the rows were simply not there.
--
-- Returns every decoded event that is missing from int_events_enriched although
-- none of the three intended filters applies to it. Each filter is restated here
-- NULL-safely, so reintroducing the `not in` form, or adding a new filter that
-- quietly drops rows, shows up as rows. Warns on any, errors past 500 (one
-- day's Vegas-I is several hundred), the same thresholds as
-- assert_no_cart_edit_loses_its_customer.

select
    d.entity_id,
    d.source_code,
    d.sales_code,
    d.username,
    d.event_at_utc
from {{ ref('int_events_decoded') }} as d
left join {{ ref('int_events_enriched') }} as e
    on e.entity_id = d.entity_id
where e.entity_id is null
  and coalesce(d.sales_code, '') <> '000'
  and (d.username is null
       or d.username not in (select username from {{ ref('seed_system_accounts') }}))
  and d.event_at_utc is not null
