{#
  A whole number as display text with thousands separators: 31939 -> '31,939'.
  Used for the workbook's "Views / Engagement" text, which must carry its unit
  ("31,939 views, 88 likes"), so the number has to be text before the unit is
  appended. NULL in, NULL out — callers rely on that to drop a missing metric
  from concat_ws().

    DuckDB      format('{:,}', x)
    Databricks  format_number(x, 0)

  Mirrors the adapter.dispatch pattern in median.sql.
#}

{% macro format_count(expression) -%}
    {{ return(adapter.dispatch('format_count', 'ust_digital_platform')(expression)) }}
{%- endmacro %}

{% macro default__format_count(expression) -%}
    format('{:,}', cast({{ expression }} as bigint))
{%- endmacro %}

{% macro databricks__format_count(expression) -%}
    format_number(cast({{ expression }} as bigint), 0)
{%- endmacro %}

{% macro spark__format_count(expression) -%}
    format_number(cast({{ expression }} as bigint), 0)
{%- endmacro %}
