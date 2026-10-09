{#
  The words of a space-separated string, sorted: 'lemon sponge jelly cake' ->
  'cake jelly lemon sponge'. Used as the MERGE key in int_social_concept_canon, so two
  spellings the LLM named with the same words in a different order are one product
  ("lemon jelly sponge cake" / "lemon sponge jelly cake" / "sponge lemon jelly cake",
  measured 2026-10-06 as three separate products).

    DuckDB      array_to_string(list_sort(string_split(x, ' ')), ' ')
    Databricks  array_join(array_sort(split(x, ' ')), ' ')

  Mirrors the adapter.dispatch pattern in median.sql.
#}

{% macro sort_words(expression) -%}
    {{ return(adapter.dispatch('sort_words', 'ust_digital_platform')(expression)) }}
{%- endmacro %}

{% macro default__sort_words(expression) -%}
    array_to_string(list_sort(string_split({{ expression }}, ' ')), ' ')
{%- endmacro %}

{% macro databricks__sort_words(expression) -%}
    array_join(array_sort(split({{ expression }}, ' ')), ' ')
{%- endmacro %}

{% macro spark__sort_words(expression) -%}
    array_join(array_sort(split({{ expression }}, ' ')), ' ')
{%- endmacro %}
