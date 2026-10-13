{#
  The key a SEARCH TERM is matched to a social concept on, when the exact name
  does not exist. Folds the three ways people write the same thing without
  meaning anything different by it:

      ma ma / mamas / mama s      -> mama
      tomyum / tom yum            -> tomyum
      instant noodle / noodles    -> instantnoodle
      coconut  milk (two spaces)  -> coconutmilk
      fishsauce / fish sauce      -> fishsauce

  WHY NOT FUZZY MATCHING. The obvious fix is an edit-distance threshold, and it
  is a trap. Measured on live search terms, the near-misses at distance 1-2 are
  overwhelmingly DIFFERENT PRODUCTS, not typos:

      milk   -> milo    1 edit   100 searches, 38 accounts
      coco   -> coke    2 edits  154 searches, 66 accounts
      ramune -> ramen   2 edits   97 searches, 25 accounts
      shark  -> shabu   2 edits   37 searches, 13 accounts

  A distance-1 rule would file 38 accounts' MILK searches under MILO. So this is
  deterministic and rule-based: whitespace and number, nothing else. It cannot
  merge two words that differ by a letter, which is exactly the property wanted.

  Builds on fold_concept (lower, trim, Vietnamese diacritics, collapse repeated
  spaces), then removes spacing entirely and drops ONE trailing plural 's'.

  The length > 3 guard keeps the plural rule off short words where a final 's'
  is part of the word -- it leaves 'gas' alone while still folding 'lays' onto
  'lay'. Same spirit as singularize(), but lowercase and one char shorter,
  because that macro works on UPPERCASE catalog tokens and its length > 4 cut
  would miss 'lays'.

  right()/left()/length()/replace() behave identically on DuckDB and Databricks,
  and fold_concept is already cross-engine, so no adapter dispatch is needed.
#}

{% macro search_match_key(col) -%}
    {%- set folded -%}
        replace({{ fold_concept(col) }}, ' ', '')
    {%- endset -%}
    case when length({{ folded }}) > 3 and right({{ folded }}, 1) = 's'
         then left({{ folded }}, length({{ folded }}) - 1)
         else {{ folded }} end
{%- endmacro %}
