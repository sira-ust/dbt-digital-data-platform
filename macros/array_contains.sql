{#
  Cross-target "is this value in the array". Both engines have it, under different
  names and argument orders:

    DuckDB     list_contains(arr, value)   (array_contains is an alias)
    Databricks array_contains(arr, value)

  DuckDB's array_contains exists but is documented against fixed-size ARRAYs, so
  list_contains is used there to stay on the LIST path the rest of this project
  builds. Mirrors the adapter.dispatch pattern in unnest.sql / array_size.sql.
#}

{% macro array_contains(column, value) -%}
    {{ return(adapter.dispatch('array_contains', 'ust_digital_platform')(column, value)) }}
{%- endmacro %}

{% macro default__array_contains(column, value) -%}
    list_contains({{ column }}, {{ value }})
{%- endmacro %}

{% macro databricks__array_contains(column, value) -%}
    array_contains({{ column }}, {{ value }})
{%- endmacro %}

{% macro spark__array_contains(column, value) -%}
    array_contains({{ column }}, {{ value }})
{%- endmacro %}
