{#
  "Today", on the reps' own clocks, taken from the DATA rather than from the
  warehouse's clock. A scalar subquery: the newest rep-local date anywhere in
  the sales event log.

  WHY NOT current_date OR current_timestamp. Both render in the session
  timezone -- UTC on Databricks, whatever the developer's machine says on
  DuckDB (Asia/Bangkok, as it happens) -- and event_at_utc is TIMESTAMP WITH
  TIME ZONE on both engines, so `cast(current_timestamp as date)` and
  `cast(event_at_utc as date)` each name a different day in dev than in prod.
  int_events_enriched already settles this once by publishing rep_local_date,
  computed from one chosen offset per rep-day, and the README forbids
  re-deriving a local date from a timestamp. This macro is how a mart asks
  "what day is it" without breaking that rule.

  It is also the more honest clock: it marks how far the event log actually
  reaches, so nothing is called finished before its events could have landed,
  and a stalled pipeline shows up as dates that stop advancing rather than as
  every rep silently going quiet.

  ONE DEFINITION, because mart_rep_daily_status and mart_rep_account_status are
  read side by side by the same assistant. If they disagreed about today by a
  day, "you visited 3 accounts yesterday" and "12 days since your last visit"
  could contradict each other in the same reply, with nothing in either table
  to show why.

  Conservative in one direction on purpose: with no rep working on a Sunday,
  this still says Saturday until Monday's first event lands.
#}
{% macro rep_log_today() -%}
    (
        select max(rep_local_date)
        from {{ ref('int_events_enriched') }}
        where actor_type     = 'sales'
          and rep_local_date is not null
    )
{%- endmacro %}
