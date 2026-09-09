{#
  Is this customer_key a test / internal account?

  Two tests, because ONE is not enough. The office (OFF001) and the ZZZ* rows
  are seeded junk, and filtering them on the OFFICE RADIUS alone misses most of
  them: eleven geocode 4.6-25.5 km away ("123 Fake St, SAN FRANCISCO", or
  literally "test"), so no radius around the office ever sees them. They score
  no visits today only because Google happened to resolve those strings
  somewhere no rep parks.

  Matched on customer_key, NEVER on customer_name: "THE LATEST SCOOP" contains
  "TEST", and NIRVANA WAREHOUSE / ALBERTSONS CORPORATE OFFICE are real accounts.

  Extracted into a macro because int_rep_customer_presence excludes these from
  the geofence candidate set while dim_customers publishes them as a FLAG — two
  different treatments of one definition, which is exactly the case where two
  copies drift.
#}
{% macro is_test_customer(col='customer_key') -%}
    (
        {{ regex_matches(col, var('test_customer_key_regex')) }}
        or {{ col }} in (
            {%- for k in var('test_customer_keys') %}
            '{{ k }}'{{ ',' if not loop.last }}
            {%- endfor %}
        )
    )
{%- endmacro %}
