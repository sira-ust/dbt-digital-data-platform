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

{% docs mysql__updated_at_dedup %}Record last update time. Latest wins on dedup.{% enddocs %}

{% docs mysql__created_at_typo %}Record creation time. Source column is `create_at` (source typo).{% enddocs %}

{% docs mysql__qty %}Quantity (string; cast in int layer if numeric operations needed).{% enddocs %}

{% docs mysql__sku %}Product SKU.{% enddocs %}

{% docs mysql__keyword %}Search keyword.{% enddocs %}

{% docs mysql__method %}Interaction method code.{% enddocs %}

{% docs mysql__timezone %}Device UTC offset string.{% enddocs %}

{% docs mysql__username_user %}Salesperson login account. Source column is `user`.{% enddocs %}

{% docs mysql__customer_id %}Customer identifier.{% enddocs %}

{% docs mysql__session_id_unpopulated %}Session identifier (currently unpopulated).{% enddocs %}

{# ---- raw (sources) ------------------------------------------------------ #}

{% docs mysql_src__updated_at %}Record last update time{% enddocs %}

{% docs mysql_src__created_at_typo %}Record creation time (note — API/DB typo, missing 'd'){% enddocs %}

{% docs mysql_src__customer_id %}Customer identifier{% enddocs %}

{% docs mysql_src__sku %}Product SKU{% enddocs %}

{% docs mysql_src__keyword %}Search keyword{% enddocs %}

{% docs mysql_src__method %}Interaction method code{% enddocs %}

{% docs mysql_src__timezone %}Device UTC offset string{% enddocs %}

{% docs mysql_src__device_model %}Device model{% enddocs %}

{% docs mysql_src__session_id_unpopulated %}Session identifier (currently unpopulated){% enddocs %}
