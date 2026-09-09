{#
  Date -> weekday NAME ('Monday'). Needed because the NUMBER is not portable:
  DuckDB's dayofweek() counts Sunday as 0, Databricks' as 1, so any arithmetic
  on the integer silently shifts by a day between dev and prod. The name has no
  such ambiguity, and it is also what a spoken answer needs.

    DuckDB     dayname(d)
    Databricks date_format(d, 'EEEE')
#}
{% macro day_name(d) -%}
    {{ return(adapter.dispatch('day_name', 'ust_digital_platform')(d)) }}
{%- endmacro %}

{% macro default__day_name(d) -%}
    dayname({{ d }})
{%- endmacro %}

{% macro databricks__day_name(d) -%}
    date_format({{ d }}, 'EEEE')
{%- endmacro %}
