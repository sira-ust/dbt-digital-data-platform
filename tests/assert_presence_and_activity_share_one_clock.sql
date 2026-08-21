-- The invariant that was only ever a COMMENT, and so silently broke.
--
-- int_rep_customer_activity and int_rep_customer_presence must read a visit and
-- the app session inside it against the SAME clock, or "was the rep in the store
-- when this happened" compares two different times of day. Both models used to
-- compute their own modal device_timezone, but over different event populations:
-- presence over 01040100 location pings (which the PDAs emit constantly),
-- activity over work events (which the iPad dominates). The PDAs never apply
-- daylight saving and the iPad does, so on 33% of rep-days in August 2026 the
-- two landed an hour apart.
--
-- What that cost: rep 026's JUN003 visit on 2026-08-17 was reported as 59
-- minutes ending 11:15, while his GPS put him within 80m of the store until
-- 12:15 and his app session ran to 12:09. A two-hour on-site stretch with 839
-- events reported as three minutes on-site and everything else "keyed
-- elsewhere". The presence model's own header CLAIMED the offsets matched.
--
-- Both now read rep_day_offset_hours from int_events_enriched, so agreement is
-- structural. This test exists so that if anyone reintroduces a local vote, the
-- build fails instead of the numbers quietly drifting.

select
    a.sales_code,
    a.activity_date,
    a.rep_day_offset_hours                                       as activity_offset,
    p.rep_day_offset_hours                                       as presence_offset
from (
    select distinct sales_code, activity_date, rep_day_offset_hours
    from {{ ref('int_rep_customer_activity') }}
) as a
join (
    select distinct sales_code, activity_date, rep_day_offset_hours
    from {{ ref('int_rep_customer_presence') }}
) as p
    on p.sales_code    = a.sales_code
   and p.activity_date = a.activity_date
where a.rep_day_offset_hours is distinct from p.rep_day_offset_hours
