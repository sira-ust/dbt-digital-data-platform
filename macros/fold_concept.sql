{#
  Normalise a concept string so Vietnamese diacritic / case / spacing variants
  collapse to ONE ranking key: "Bánh Khọt", "banh khot", "Bánh  Khọt" -> "banh khot".
  Without this the same dish ranks several times (once per spelling), wasting slots.

  Deterministic and cross-engine: lower + trim, translate() folds every accented
  Vietnamese vowel (and đ) to its ASCII base, then multiple spaces collapse to one.
  translate() and regexp_replace() behave identically on DuckDB and Databricks, so
  no adapter dispatch is needed. The from/to strings are 67 chars each, position-
  aligned (generated 2026-07-30).

  NOTE: this only merges Latin-script diacritic variants. Cross-SCRIPT / synonym
  dupes (som tam vs ส้มตำ, boat noodles vs kuay tiew reua) are NOT merged here —
  that needs the LLM canonical key, a possible follow-up.
#}

{% macro fold_concept(col) -%}
    regexp_replace(
        translate(
            lower(trim({{ col }})),
            'àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ',
            'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd'
        ),
        ' +', ' '
    )
{%- endmacro %}
