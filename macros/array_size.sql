{#
  Cross-target array length. Both engines have a length function for arrays, but
  not under a shared name:

    DuckDB     array_length(arr)   (len() is the alias)
    Databricks size(arr)           (array_size() exists only on newer DBRs)

  Returns 0 for an empty array and NULL for a NULL array on both, so a
  length comparison between two arrays needs coalesce() if either can be NULL.

  Mirrors the adapter.dispatch pattern in unnest.sql / parse_response.sql.
#}

{% macro array_size(column) -%}
    {{ return(adapter.dispatch('array_size', 'ust_digital_platform')(column)) }}
{%- endmacro %}

{% macro default__array_size(column) -%}
    array_length({{ column }})
{%- endmacro %}

{% macro databricks__array_size(column) -%}
    size({{ column }})
{%- endmacro %}

{% macro spark__array_size(column) -%}
    size({{ column }})
{%- endmacro %}
