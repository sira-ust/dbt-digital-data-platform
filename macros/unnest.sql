{#
  Cross-target array explode. DuckDB and Databricks both accept a set-returning
  function in the SELECT list that replicates the row's scalar columns per
  element, but they spell it differently:

    DuckDB     select id, unnest(arr)  as x from t
    Databricks select id, explode(arr) as x from t

  Use exactly ONE unnest() per SELECT (both engines allow only one generator per
  select list); UNION ALL the per-array streams. null / empty arrays yield zero
  rows on both engines, so filter the exploded value for emptiness downstream.

  Mirrors the adapter.dispatch pattern in parse_response.sql. Add a fabric__
  override if Fabric is ever chosen (T-SQL uses CROSS APPLY string_split / OPENJSON).
#}

{% macro unnest(column) -%}
    {{ return(adapter.dispatch('unnest', 'ust_digital_platform')(column)) }}
{%- endmacro %}

{% macro default__unnest(column) -%}
    unnest({{ column }})
{%- endmacro %}

{% macro databricks__unnest(column) -%}
    explode({{ column }})
{%- endmacro %}

{% macro spark__unnest(column) -%}
    explode({{ column }})
{%- endmacro %}
