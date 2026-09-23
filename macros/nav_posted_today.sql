{#
  "Today", on the NAV POSTED-SALES clock: the newest posting_date anywhere in
  stg_nav__sales_invoice_lines. A scalar subquery, taken from the DATA rather
  than from the warehouse's clock, for the same reasons rep_log_today() is —
  current_date renders in the session timezone (UTC on Databricks, the
  developer's zone on DuckDB) and would name a different day in dev than in
  prod.

  WHY THIS IS A SECOND CLOCK AND NOT rep_log_today(). These are two independent
  feeds with two independent leading edges:

    rep_log_today()     the mysql event log. Advances when a rep uses the app.
    nav_posted_today()  the NAV ERP replica. Advances when an invoice POSTS.

  An invoice posts days after the order was keyed, and posts whether or not
  anyone opened the app; the ERP full-load also runs on its own schedule. So
  the two edges genuinely differ, and by a variable amount. Measuring "days
  since this account last bought item X" against the EVENT log's today would add
  or subtract that difference from every age in the table — silently, and
  differently each run.

  THE RULE, and it is the whole point of having two macros instead of one:
  measure an age against the clock of the feed the fact came from.

    a purchase, a return, a reorder-due date   -> nav_posted_today()
    a visit, an app session, a submitted order -> rep_log_today()

  Marts that publish both must publish BOTH as-of dates, never one relabelled
  as the other. mart_account_item_history does exactly that, and its
  purchase_as_of_date column is this value.

  Conservative in the same direction as rep_log_today(): if the ERP feed stalls,
  this stops advancing rather than ageing every account's purchases by a day
  per day, so a stalled pipeline shows up as a frozen date instead of as every
  customer appearing to lapse at once.
#}
{% macro nav_posted_today() -%}
    (
        select max(posting_date)
        from {{ ref('stg_nav__sales_invoice_lines') }}
    )
{%- endmacro %}
