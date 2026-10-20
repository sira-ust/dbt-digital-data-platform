{#
  promo_search_language(col) — the language of a promo search phrase, read from its
  script: 'Japanese' | 'Chinese' | 'Thai' | 'Khmer' | 'Vietnamese' | 'English'.

  The workbook gives each language its own column block, and the scraped videos are
  capped per item AND language, so a Vietnamese or Chinese search's results are not
  crowded out by an English one's bigger view counts.

  Script, not meaning: any kana -> Japanese (checked FIRST: a Japanese phrase mixes kana
  with kanji, and kanji are Chinese characters, so a Chinese-first check filed Japanese
  under Chinese — NOV 2026, Hata and Morinaga Moonlight), CJK ideographs with no kana ->
  Chinese, Thai block -> Thai, Khmer block ->
  Khmer, any Vietnamese-only letter (ă â đ ê ô ơ ư and the tone marks) -> Vietnamese,
  anything else -> English. A Vietnamese phrase typed without diacritics reads as
  English; the drafted phrases always carry them. Khmer and Japanese are detected only so
  they can be LEFT OUT: neither is searched nor has a workbook block (2026-10-20), and
  without its own branch a Khmer phrase would fall through to English and a Japanese one
  to Chinese.

  LITERAL CHARACTERS, NO BACKSLASHES: DuckDB and Databricks disagree on escaping inside
  a regex string (see strip_parenthetical_gloss), and regexp_extract behaves the same on
  both (see parse_response). KEEP IN STEP with phrase_language() in
  scripts/promo_common.py, which labels the TikTok list's phrases with the same rule.
#}
{% macro promo_search_language(col) -%}
    case
        when {{ col }} is null then null
        when regexp_extract({{ col }}, '([ぁ-ゟ゠-ヿㇰ-ㇿｦ-ﾟ])', 1) <> '' then 'Japanese'
        when regexp_extract({{ col }}, '([一-鿿㐀-䶿])', 1) <> '' then 'Chinese'
        when regexp_extract({{ col }}, '([฀-๿])', 1) <> '' then 'Thai'
        when regexp_extract({{ col }}, '([ក-៿])', 1) <> '' then 'Khmer'
        when regexp_extract(lower({{ col }}),
             '([ăâđêôơưàảãáạằẳẵắặầẩẫấậèẻẽéẹềểễếệìỉĩíịòỏõóọồổỗốộờởỡớợùủũúụừửữứựỳỷỹýỵ])', 1) <> ''
            then 'Vietnamese'
        else 'English'
    end
{%- endmacro %}
