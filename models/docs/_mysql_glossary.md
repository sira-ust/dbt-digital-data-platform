{# ---------------------------------------------------------------------------
   Shared column definitions for the mysql staging layer.

   Edit a definition HERE and every column that references it via
   {{ doc('...') }} updates at once. Two families:

     mysql__*      staged (analytics-friendly) column meanings  -> _mysql__models.yml
     mysql_src__*  raw source column meanings (as landed)       -> _mysql__sources.yml

   Source and staged blocks are kept separate on purpose: the raw description
   records the field as-is (warts, typos, raw name) while the staged one
   describes the cleaned/renamed column. Only put a definition here when the
   SAME text is used by 2+ columns; leave one-off or rename-note text inline.
--------------------------------------------------------------------------- #}

{# ---- staged (models) ---------------------------------------------------- #}

{% docs mysql__created_at_typo %}Record creation time. Source column is `create_at` (source typo).{% enddocs %}

{# ---- raw (sources) ------------------------------------------------------ #}

{% docs mysql_src__updated_at %}Record last update time{% enddocs %}

