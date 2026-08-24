{#
  Carry the most recent NON-NULL value of a column forward over a window —
  the "last known state" pattern, used by int_rep_customer_activity to hold a
  BLE pairing (and the customer it named) across the events that follow it.

  IGNORE NULLS is standard SQL but the two engines place it differently:
    DuckDB      last_value(col IGNORE NULLS) OVER (...)
    Databricks  last_value(col) IGNORE NULLS OVER (...)
  Getting it wrong is a parse error, not a wrong answer, so this dispatches
  rather than picking one and hoping. Verified on both 2026-08-21.

  Omitting IGNORE NULLS is NOT an option: last_value would return the null on
  every row that is not itself a state change, which is almost all of them.
#}

{% macro carry_forward(col, window_sql) -%}
    {%- if target.type == 'duckdb' -%}
        last_value({{ col }} ignore nulls) over ({{ window_sql }})
    {%- else -%}
        last_value({{ col }}) ignore nulls over ({{ window_sql }})
    {%- endif -%}
{%- endmacro %}
