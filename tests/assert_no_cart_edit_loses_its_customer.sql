{{ config(severity = 'error', warn_if = '>0', error_if = '>500') }}

-- Regression guard for the BLE attribution bug (found 2026-08-21).
--
-- BLE pairing transfers the open cart from the iPad to the PDA, after which the
-- iPad's own events carry no ust_customer_no. int_rep_customer_activity used to
-- filter `customer_key is not null` BEFORE inheriting one, which silently
-- dropped 15,221 of 22,800 cart edits made on a paired iPad in Aug 2026 (66.8%)
-- and made real store visits read as "no app activity" — rep 026 showed 2 events
-- against a 131-minute GPS visit at NEW051 on 2026-08-17.
--
-- A cart edit is the one event class that can never legitimately lack a
-- customer: it edits a specific customer's order. So a cart edit present in
-- int_events_enriched for a sales actor but absent from the activity spine means
-- attribution has regressed.
--
-- SCOPE — from 2026-05-01, the month PDA cart edits started carrying the
-- customer 100% of the time (Jan-Apr 2026 lost 49,384 on the PDA alone, an
-- app-side gap we cannot repair from the event log and must not pretend to).
-- Measured 2026-08-21 across 2026-05-01..08-20: 242 rows, all iPad, all in July,
-- where no BLE session or recent PDA customer existed to inherit from. Hence
-- warn at >0 so the count stays visible, error at >500 so a real regression —
-- the old behaviour was 15,530 in August alone — breaks the build.

select i.entity_id
from {{ ref('int_events_enriched') }} as i
left join {{ ref('int_rep_customer_activity') }} as o
    on o.entity_id = i.entity_id
where i.actor_type = 'sales'
  and i.sales_code is not null
  and (i.is_add or i.is_remove or i.is_qty_change)
  and i.event_at_utc >= cast('{{ var("ble_attribution_guard_from") }}' as timestamp)
  and o.entity_id is null
