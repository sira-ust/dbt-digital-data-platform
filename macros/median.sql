{#
  Cross-target median of an expression, as an aggregate.

    DuckDB     median(x) / quantile_cont(x, 0.5)
    Databricks percentile_approx(x, 0.5) — median() needs a newer DBR

  The SQL-standard `percentile_cont(0.5) within group (order by x)` works on
  both, but cannot be nested inside a case expression, so each target gets its
  own spelling instead.

  NULLs are ignored by both, which is what callers want: passing
  `case when is_add then gap end` measures the gap between ADDS only and lets
  every other event drop out, rather than counting them as zero.

  Mirrors the adapter.dispatch pattern in array_size.sql / parse_response.sql.
#}

{% macro median(expression) -%}
    {{ return(adapter.dispatch('median', 'ust_digital_platform')(expression)) }}
{%- endmacro %}

{% macro default__median(expression) -%}
    median({{ expression }})
{%- endmacro %}

{% macro databricks__median(expression) -%}
    percentile_approx({{ expression }}, 0.5)
{%- endmacro %}

{% macro spark__median(expression) -%}
    percentile_approx({{ expression }}, 0.5)
{%- endmacro %}
