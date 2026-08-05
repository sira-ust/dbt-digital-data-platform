{#
  Strip a trailing "(...)" gloss the LLM sometimes appends when extracting a
  dish name — e.g. "ขนมโตเกียว (tokyo pastry/snack)" instead of plain
  "ขนมโตเกียว". Wording isn't consistent call to call, so the same dish
  fragments across several concepts (verified on real data: one Thai snack
  split 4 ways — "(tokyo pastry/snack)", "(tokyo snack/pastry)", "(tokyo
  treat/pastry)", and plain — 18 real mentions collapsed to 10 visible).

  Only strips ONE trailing parenthetical (anchored to end of string), so
  "banh mi (chicken) extra (spicy)" only loses the trailing "(spicy)" —
  deliberately conservative; a parenthetical in the MIDDLE of a string is
  left alone, since it might be a genuine qualifier, not a gloss.

  NOT identical across engines, unlike fold_concept's translate()/space-collapse
  regexp_replace(): DuckDB and Databricks disagree on backslash-escaping inside
  a regex string literal. Confirmed by testing both directly:
    - \(  alone is a HARD ERROR on Databricks ([INVALID_PARAMETER_VALUE.PATTERN])
      — its string-literal parser eats the single backslash before the regex
      engine ever sees it, leaving a bare unmatched "(".
    - \\( (doubled) is required on Databricks to get a literal "\(" through to
      the regex engine; DuckDB wants the single-backslash form instead.
    - The end-of-string anchor "$" is unescaped and identical on both.
  Hence the adapter dispatch below, rather than one shared expression.
#}

{% macro strip_parenthetical_gloss(col) -%}
    {{ return(adapter.dispatch('strip_parenthetical_gloss', 'ust_digital_platform')(col)) }}
{%- endmacro %}

{% macro default__strip_parenthetical_gloss(col) -%}
    regexp_replace(trim({{ col }}), '\s*\([^)]*\)$', '')
{%- endmacro %}

{% macro databricks__strip_parenthetical_gloss(col) -%}
    regexp_replace(trim({{ col }}), '\\s*\\([^)]*\\)$', '')
{%- endmacro %}

{% macro spark__strip_parenthetical_gloss(col) -%}
    regexp_replace(trim({{ col }}), '\\s*\\([^)]*\\)$', '')
{%- endmacro %}
