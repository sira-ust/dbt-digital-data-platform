{#
  Reusable parsers for the `response` payload column.
  The payload is NOT JSON — formats vary by event family:

    kv CSV:           category:8888,visits_num:2,time:15
    positional CSV:   M000072209,CAT,1250.00,45,1100.00,8,ASI325
    duration:         Time:42
    bare value:       a SKU, a title, 'Fail', or empty

  regexp_extract/split_part work on DuckDB and Databricks with the same
  signature. If Fabric is chosen, add fabric__ overrides (T-SQL lacks both).
#}


{# kv CSV — extract the value for one key, e.g. parse_kv_response('response', 'visits_num') #}
{% macro parse_kv_response(column, key) -%}
    {{ return(adapter.dispatch('parse_kv_response', 'ust_digital_platform')(column, key)) }}
{%- endmacro %}

{# space-tolerant: the order-submit payload has ", key:val" (space after comma)
   while the catalog-view payload has "key:val,key:val" (no spaces). Optional
   spaces around the comma/colon match both; trimming leaves no-space values
   unchanged, so this stays backward-compatible with int_catalog_dwell. #}
{% macro default__parse_kv_response(column, key) -%}
    nullif(trim(regexp_extract({{ column }}, '(^|,) *{{ key }} *:([^,]*)', 2)), '')
{%- endmacro %}


{# positional CSV — 1-based part index, e.g. response_part('response', 3) -> grand_total #}
{% macro response_part(column, idx) -%}
    {{ return(adapter.dispatch('response_part', 'ust_digital_platform')(column, idx)) }}
{%- endmacro %}

{% macro default__response_part(column, idx) -%}
    nullif(trim(split_part({{ column }}, ',', {{ idx }})), '')
{%- endmacro %}


{# duration — 'Time:42' -> 42 (seconds, integer; null if absent) #}
{% macro parse_duration_seconds(column) -%}
    {{ return(adapter.dispatch('parse_duration_seconds', 'ust_digital_platform')(column)) }}
{%- endmacro %}

{% macro default__parse_duration_seconds(column) -%}
    try_cast(regexp_extract({{ column }}, 'Time:([0-9]+)', 1) as integer)
{%- endmacro %}
