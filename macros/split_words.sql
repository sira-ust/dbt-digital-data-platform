{#
  A space-separated string as an array of its words: 'lemon jelly cake' ->
  ['lemon', 'jelly', 'cake']. Pair with unnest() to get one row per word.

    DuckDB      string_split(x, ' ')
    Databricks  split(x, ' ')

  Mirrors the adapter.dispatch pattern in median.sql.
#}

{% macro split_words(expression) -%}
    {{ return(adapter.dispatch('split_words', 'ust_digital_platform')(expression)) }}
{%- endmacro %}

{% macro default__split_words(expression) -%}
    string_split({{ expression }}, ' ')
{%- endmacro %}

{% macro databricks__split_words(expression) -%}
    split({{ expression }}, ' ')
{%- endmacro %}

{% macro spark__split_words(expression) -%}
    split({{ expression }}, ' ')
{%- endmacro %}
