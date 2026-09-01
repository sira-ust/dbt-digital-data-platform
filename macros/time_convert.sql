{#
  Timezone / epoch helpers. Two distinct conversions exist in this source:

  1. event_time — FORMAT-DEPENDENT, see event_time_to_utc below. The live
     MySQL stores an epoch value, which is already UTC by definition; the
     local JSON sample stores a device-LOCAL datetime string, which needs the
     row's `timezone` column ("GMT+8" style offset) applied. Applying the
     offset to an epoch value is a double conversion — it was doing exactly
     that until 2026-08-13, which pushed every GMT-8 event 8h forward and put
     the apparent activity peak at 16:00-21:00 instead of 09:00-13:00.
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


{# event_time -> timestamp, format-agnostic. The column is kept as a raw string
   in staging because its format varies by source: the live MySQL stores an
   epoch value (seconds, or milliseconds when >= 12 digits) while the local JSON
   sample stores a datetime string. All-digit values are read as epoch; anything
   else is parsed as a datetime string. Null/blank/garbage -> null. #}
{% macro event_time_to_ts(column) -%}
    {{ return(adapter.dispatch('event_time_to_ts', 'ust_digital_platform')(column)) }}
{%- endmacro %}

{% macro default__event_time_to_ts(column) -%}
    case
        when nullif(trim(cast({{ column }} as {{ dbt.type_string() }})), '') is null then null
        when regexp_matches(trim(cast({{ column }} as {{ dbt.type_string() }})), '^[0-9]{12,}$')
            then to_timestamp(try_cast({{ column }} as bigint) / 1000.0)
        when regexp_matches(trim(cast({{ column }} as {{ dbt.type_string() }})), '^[0-9]+$')
            then to_timestamp(try_cast({{ column }} as bigint))
        else try_cast({{ column }} as timestamp)
    end
{%- endmacro %}

{% macro databricks__event_time_to_ts(column) -%}
    case
        when nullif(trim({{ column }}), '') is null then null
        when {{ column }} rlike '^[0-9]{12,}$' then timestamp_millis(try_cast({{ column }} as bigint))
        when {{ column }} rlike '^[0-9]+$' then timestamp_seconds(try_cast({{ column }} as bigint))
        else try_cast({{ column }} as timestamp)
    end
{%- endmacro %}


{# Sort an array ascending. array_agg gives NO ordering guarantee on either
   engine — ordering the input subquery does not survive the aggregate — so any
   array meant to READ in order has to be sorted after the fact. Spelling
   differs: duckdb list_sort, databricks array_sort. #}
{% macro sort_array(arr) -%}
    {{ return(adapter.dispatch('sort_array', 'ust_digital_platform')(arr)) }}
{%- endmacro %}

{% macro default__sort_array(arr) -%}
    list_sort({{ arr }})
{%- endmacro %}

{% macro databricks__sort_array(arr) -%}
    array_sort({{ arr }})
{%- endmacro %}


{# Timestamp -> 'HH:mm' clock string. duckdb has strftime, databricks has
   date_format, and neither knows the other's name — isolate it here. #}
{% macro format_hhmm(ts) -%}
    {{ return(adapter.dispatch('format_hhmm', 'ust_digital_platform')(ts)) }}
{%- endmacro %}

{% macro default__format_hhmm(ts) -%}
    strftime({{ ts }}, '%H:%M')
{%- endmacro %}

{% macro databricks__format_hhmm(ts) -%}
    date_format({{ ts }}, 'HH:mm')
{%- endmacro %}


{# A typed NULL array of strings, for the empty side of a UNION ALL.

   The type CANNOT be left to inference: in a `union all` both branches must
   agree, and a bare `null` has no element type to match the array_agg on the
   other side.

   The spelling is where this bites. duckdb writes `varchar[]`, databricks
   writes `array<string>`, and NEITHER parses the other -- `cast(null as
   string[])` fails on databricks with PARSE_SYNTAX_ERROR at the '['. That is a
   compile-time failure that duckdb cannot surface, so it only ever appears on
   a real databricks run. #}
{% macro null_string_array() -%}
    {{ return(adapter.dispatch('null_string_array', 'ust_digital_platform')()) }}
{%- endmacro %}

{% macro default__null_string_array() -%}
    cast(null as {{ dbt.type_string() }}[])
{%- endmacro %}

{% macro databricks__null_string_array() -%}
    cast(null as array<{{ dbt.type_string() }}>)
{%- endmacro %}


{# Is this event_time an epoch value (all digits) rather than a datetime string?
   Decides whether the device tz offset must be applied — see event_time_to_utc. #}
{% macro event_time_is_epoch(column) -%}
    {{ return(adapter.dispatch('event_time_is_epoch', 'ust_digital_platform')(column)) }}
{%- endmacro %}

{% macro default__event_time_is_epoch(column) -%}
    regexp_matches(trim(cast({{ column }} as {{ dbt.type_string() }})), '^[0-9]+$')
{%- endmacro %}

{% macro databricks__event_time_is_epoch(column) -%}
    cast({{ column }} as string) rlike '^[0-9]+$'
{%- endmacro %}


{# event_time -> TRUE UTC, branching on the stored format.

   epoch            already UTC (that is what an epoch IS) -> use as-is.
   datetime string  device LOCAL wall clock -> UTC = local - offset, so for
                    GMT-8 we ADD 8h. A null/unparseable timezone falls back to
                    offset 0, i.e. the string is taken at face value.

   Applying the offset in both branches is the double-conversion bug fixed
   2026-08-13; it silently skewed every timestamp in the warehouse by up to 9h. #}
{% macro event_time_to_utc(column, tz_column) -%}
    case
        when {{ event_time_is_epoch(column) }}
            then {{ event_time_to_ts(column) }}
        else {{ add_hours(
                   event_time_to_ts(column),
                   '-coalesce(' ~ tz_offset_hours(tz_column) ~ ', 0)'
               ) }}
    end
{%- endmacro %}


{# Great-circle distance between two lat/lon pairs, in METRES.

   Pure arithmetic, so no adapter dispatch is needed — sin/cos/asin/sqrt/radians
   are spelled the same on duckdb and databricks.

   ALWAYS pair this with a bounding-box prefilter in the join condition. On
   415k GPS fixes x 2.8k stores a naive cross join took 27s; adding
   `abs(lat_a - lat_b) < r/110000` first took it to 7.8s (measured 2026-08-13).
   1 degree of latitude is ~110km everywhere; 1 degree of longitude is ~85km at
   37N, so the longitude divisor is the tighter, latitude-dependent one — the
   values above are deliberately generous so the box never clips a true match. #}
{% macro haversine_metres(lat_a, lon_a, lat_b, lon_b) -%}
    (2 * 6371000 * asin(sqrt(
        pow(sin(radians(({{ lat_b }}) - ({{ lat_a }})) / 2), 2)
        + cos(radians({{ lat_a }})) * cos(radians({{ lat_b }}))
        * pow(sin(radians(({{ lon_b }}) - ({{ lon_a }})) / 2), 2)
    )))
{%- endmacro %}


{# Do two arrays share at least one element? Used to tell a visit's arrival leg
   from a stop of its own: if a no-activity visit shares a GPS fix with a visit
   that HAS activity, it is the same moment seen through a neighbour's fence.
   duckdb spells it list_has_any, databricks arrays_overlap. #}
{% macro arrays_overlap(a, b) -%}
    {{ return(adapter.dispatch('arrays_overlap', 'ust_digital_platform')(a, b)) }}
{%- endmacro %}

{% macro default__arrays_overlap(a, b) -%}
    list_has_any({{ a }}, {{ b }})
{%- endmacro %}

{% macro databricks__arrays_overlap(a, b) -%}
    arrays_overlap({{ a }}, {{ b }})
{%- endmacro %}


{# Regex match. databricks spells it `rlike`, duckdb `regexp_matches`; neither
   parses the other, and duckdb cannot surface a databricks-only parse failure
   at dev time. #}
{% macro regex_matches(col, pattern) -%}
    {{ return(adapter.dispatch('regex_matches', 'ust_digital_platform')(col, pattern)) }}
{%- endmacro %}

{% macro default__regex_matches(col, pattern) -%}
    (regexp_matches({{ col }}, '{{ pattern }}'))
{%- endmacro %}

{# parenthesised: `not a rlike b` is precedence-fragile, `not (a rlike b)` is not #}
{% macro databricks__regex_matches(col, pattern) -%}
    ({{ col }} rlike '{{ pattern }}')
{%- endmacro %}


{# Distinct elements of an array. A customer with two scenario rows joins to its
   presence rows twice, so any array_agg over that join double-counts unless the
   duplicates are removed -- which silently broke fix-set equality.
   duckdb list_distinct, databricks array_distinct. #}
{% macro array_distinct(arr) -%}
    {{ return(adapter.dispatch('array_distinct', 'ust_digital_platform')(arr)) }}
{%- endmacro %}

{% macro default__array_distinct(arr) -%}
    list_distinct({{ arr }})
{%- endmacro %}

{% macro databricks__array_distinct(arr) -%}
    array_distinct({{ arr }})
{%- endmacro %}
