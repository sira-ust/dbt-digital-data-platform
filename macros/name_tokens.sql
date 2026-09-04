{#
  Normalise an item name into a SPACE-PADDED, upper-cased token string, so that
  the same expression serves both "split it into tokens" and "does it contain
  token X" (`like '% TOK %'`) without either operation needing a regex.

      'DF OYSTER SAUCE(GLASS)'  ->  ' DF OYSTER SAUCE GLASS '

  NO REGEX, deliberately. regexp_replace does NOT behave the same on both
  engines: DuckDB replaces only the FIRST match unless a 'g' flag is passed,
  while Databricks always replaces globally (verified 2026-09-03,
  regexp_replace('a  b  c', ' +', ' ') -> 'a b  c' on DuckDB, 'a b c' on
  Databricks). translate() IS identical on both — the same property
  fold_concept relies on — so punctuation is mapped to spaces character by
  character instead.

  Leading/trailing padding is what makes `like '% TOK %'` a TOKEN test rather
  than a substring test. That distinction is the whole point: without it,
  'coconut water' matches 'MOGU WATERMELON NATA DE COCO' through the substring
  WATER, which is how the first version of the alternates logic proposed
  watermelon drinks as alternatives to coconut water.

  Runs of several spaces are fine and are NOT collapsed: splitting on ' ' just
  yields empty strings between them, and every caller filters tokens by length.

  DIGITS ARE MAPPED TO SPACES TOO. They are pack sizes, years and case counts —
  never what a product IS — and leaving them attached welds a real word to a
  number: 'LKK PREMIUM OYSTER SCE18OZ(12)' tokenises to SCE18OZ, which matches
  nothing and no abbreviation map can reach. Split there and it becomes SCE + OZ,
  and SCE -> SAUCE puts that SKU back on the oyster-sauce list where it belongs.
#}

{% macro normalize_item_name(col) -%}
    {%- set punct = "&()#*/,.%-+[]:;!?0123456789" -%}
    concat(' ', upper(translate({{ col }}, '{{ punct }}', '{{ " " * punct | length }}')), ' ')
{%- endmacro %}
