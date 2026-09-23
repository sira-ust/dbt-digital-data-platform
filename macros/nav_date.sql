{#
  A NAV date, with the blank sentinel turned into NULL.

  NAV DOES NOT WRITE NULL FOR AN UNSET DATE. Business Central stores a blank
  date as 1753-01-01 — SQL Server's datetime minimum — and that value survives
  the ADF export and the DLT pipeline untouched. Verified against
  ust_databricks.navrep on 2026-09-23: item.new_end_date is 1753-01-01 on all
  357 flagged items and NULL on none of them.

  So `where end_date is null` finds nothing, and `current_date between begin and
  end` is silently FALSE for every unset row rather than erroring. That is
  exactly how the new-item window came to look like "no item is ever new": the
  flag was set on 357 items and the window could never be satisfied because its
  end was blank. The bug is invisible — no failure, no warning, just a zero.

  Convert ONCE, in staging, so no mart has to remember the sentinel exists.

  1753-01-02 rather than an equality test on 1753-01-01: the export lands these
  as timestamps and a stray time component on the sentinel would slip past `=`.
  Nothing real is dated in 1753, so the range is safe.
#}
{% macro nav_date(column) -%}
    case
        when cast({{ column }} as date) > cast('1753-01-02' as date)
            then cast({{ column }} as date)
    end
{%- endmacro %}
