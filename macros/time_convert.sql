{#
  Timezone / epoch helpers. Two distinct conversions exist in this source:

  1. event_time  — DEVICE local time; convert to UTC using the row's
     `timezone` column ("GMT+8" style device UTC offset).
  2. created_at / updated_at — SERVER time, fixed PST (UTC-8) year-round
     with NO daylight saving. Convert with a CONSTANT +8h offset, never a
     tz-rules conversion (rules would wrongly apply DST).

  Engine-specific interval syntax is isolated here; production engine TBD.
#}


{# add a (possibly negative) number of hours to a timestamp #}
{% macro add_hours(ts, hours) -%}
    {{ return(adapter.dispatch('add_hours', 'ust_digital_platform')(ts, hours)) }}
{%- endmacro %}

{% macro default__add_hours(ts, hours) -%}
    ({{ ts }} + interval ({{ hours }}) hour)
{%- endmacro %}

{% macro databricks__add_hours(ts, hours) -%}
    timestampadd(hour, {{ hours }}, {{ ts }})
{%- endmacro %}


{# parse the device offset hours out of 'GMT+8' / 'GMT-11'; null if absent #}
{# TODO: half-hour offsets (GMT+5:30) — extend if profiling shows any #}
{% macro tz_offset_hours(column) -%}
    try_cast(regexp_extract({{ column }}, 'GMT([+-][0-9]{1,2})', 1) as integer)
{%- endmacro %}


{# epoch milliseconds (string or number) -> timestamp; null on garbage #}
{% macro epoch_millis_to_ts(column) -%}
    {{ return(adapter.dispatch('epoch_millis_to_ts', 'ust_digital_platform')(column)) }}
{%- endmacro %}

{% macro default__epoch_millis_to_ts(column) -%}
    to_timestamp(try_cast({{ column }} as bigint) / 1000.0)
{%- endmacro %}

{% macro databricks__epoch_millis_to_ts(column) -%}
    timestamp_millis(try_cast({{ column }} as bigint))
{%- endmacro %}
