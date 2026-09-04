{#
  Drop a trailing plural "S" so NOODLES and NOODLE are the same token.

  Needed because the concept and the catalog disagree on number as a matter of
  habit: people write "rice noodles", the master writes "DF RICE NOODLE (RED
  LABEL)". With the plural intact the NOODLE anchor never matched, so the only
  surviving anchor for "rice noodles" was RICE and the list filled with anything
  rice-shaped in that family, FAIRY RICE FLAKE included (observed 2026-09-03).

  Deliberately crude, and safe BECAUSE it is applied to both sides. It is not a
  stemmer: GRASS becomes GRAS, which is wrong as English and completely harmless
  here, since the catalog token and the concept token are folded the same way and
  still meet. Length > 4 keeps it off short tokens where the S is usually part of
  the word (PCS, GAS).

  left()/right() and length() behave identically on DuckDB and Databricks.
#}

{% macro singularize(col) -%}
    case when length({{ col }}) > 4 and right({{ col }}, 1) = 'S'
         then left({{ col }}, length({{ col }}) - 1)
         else {{ col }} end
{%- endmacro %}
