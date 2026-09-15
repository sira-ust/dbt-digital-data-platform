-- on_site_worked_minutes is the portion of a GPS visit that an app session
-- covered, so it can never be longer than the visit itself. The two were
-- indistinguishable by name until 2026-09-15 (the mart's column was called
-- on_site_minutes, the same name int_rep_customer_presence uses for the visit
-- DURATION), and a consumer reading the mart's the obvious way overstated one
-- rep's week by 54%.
--
-- The rename fixes the ambiguity; this locks the relationship so the two cannot
-- silently drift into meaning the same thing again. Verified 0 violations over
-- 90 days at the time of writing.

select
    customer_day_key,
    sales_code,
    customer_key,
    activity_date,
    scenario,
    on_site_worked_minutes,
    visit_minutes,
    visit_stops
from {{ ref('mart_rep_customer_activity') }}
where visit_minutes is not null
  and on_site_worked_minutes > visit_minutes
