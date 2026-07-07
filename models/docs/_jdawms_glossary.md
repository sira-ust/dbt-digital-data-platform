{# ---------------------------------------------------------------------------
   Shared RAW column definitions for the jdawms (JDA/Blue Yonder WMS) source.

   Edit a definition HERE and every column that references it via
   {{ doc('...') }} in _jdawms__sources.yml updates at once.

   Rule: a definition lives here only when the SAME text is used by 2+ columns
   (nearly always the same column name repeated across tables). One-off or
   column-specific text stays inline in the YAML.

   Slug convention: jdawms__<column_name>. Block names are project-global.
--------------------------------------------------------------------------- #}

{% docs jdawms__loaddate %}Ingestion timestamp — when this row was loaded into the lakehouse (pipeline watermark, not a business field).{% enddocs %}

{% docs jdawms__wh_id %}Warehouse (facility) identifier.{% enddocs %}

{% docs jdawms__prt_client_id %}Client/owner id for the part (multi-client warehouse partitioning).{% enddocs %}

{% docs jdawms__prtnum %}Part (item) number — the SKU identifier.{% enddocs %}

{% docs jdawms__ins_dt %}Row insert timestamp in the source WMS.{% enddocs %}

{% docs jdawms__ins_user_id %}User/process that inserted the row in the WMS.{% enddocs %}

{% docs jdawms__last_upd_dt %}Row last-update timestamp in the source WMS.{% enddocs %}

{% docs jdawms__last_upd_user_id %}User/process that last updated the row in the WMS.{% enddocs %}

{% docs jdawms__ftpcod %}Fetch/pack-type code — packaging configuration key for the part.{% enddocs %}

{% docs jdawms__u_version %}Optimistic-lock version counter maintained by the WMS.{% enddocs %}

{% docs jdawms__adddte %}Timestamp the record was created/added.{% enddocs %}

{% docs jdawms__mod_usr_id %}User/process that last modified the row in the WMS.{% enddocs %}

{% docs jdawms__rowid %}Source database internal row identifier.{% enddocs %}

{% docs jdawms___rescued_data %}Auto Loader rescued-data column — captures values that did not fit the schema on ingest; normally null.{% enddocs %}

{% docs jdawms__asset_typ %}Material-handling asset type (e.g. pallet, tote).{% enddocs %}

{% docs jdawms__client_id %}Client/owner id for the record (multi-client warehouse partitioning).{% enddocs %}

{% docs jdawms__invsts %}Inventory status code (e.g. available, hold, damaged).{% enddocs %}

{% docs jdawms__lodnum %}License-plate / load (LPN) number.{% enddocs %}

{% docs jdawms__lst_usr_id %}User associated with the last activity.{% enddocs %}

{% docs jdawms__lstcod %}Code describing the last activity/movement type.{% enddocs %}

{% docs jdawms__lstdte %}Timestamp of the last activity against this record.{% enddocs %}

{% docs jdawms__moddte %}Last-modified timestamp in the source WMS.{% enddocs %}

{% docs jdawms__ship_id %}Shipment identifier.{% enddocs %}

{% docs jdawms__stoloc %}Storage location (slot) code.{% enddocs %}

{% docs jdawms__subnum %}Sub (carton/case) number nested within a load.{% enddocs %}

{% docs jdawms__untcas %}Units per case.{% enddocs %}

{% docs jdawms__wrkref %}Pick-work reference (task) identifier.{% enddocs %}

{% docs jdawms__catch_qty %}Catch weight/quantity (variable-weight items).{% enddocs %}

{% docs jdawms__devcod %}Device code that performed/recorded the activity.{% enddocs %}

{% docs jdawms__dtlnum %}Inventory detail number (innermost unit).{% enddocs %}

{% docs jdawms__est_time %}Estimated task time (system-computed).{% enddocs %}

{% docs jdawms__lodlvl %}Load level indicator.{% enddocs %}

{% docs jdawms__lstmov %}Timestamp of the last movement of this unit.{% enddocs %}

{% docs jdawms__ordnum %}Order number.{% enddocs %}

{% docs jdawms__pckqty %}Picked quantity (planned to pick).{% enddocs %}

{% docs jdawms__schbat %}Scheduled batch / wave identifier.{% enddocs %}

{% docs jdawms__ship_line_id %}Shipment line identifier.{% enddocs %}

{% docs jdawms__untpak %}Units per pack/inner.{% enddocs %}

{% docs jdawms__untqty %}Quantity in stock/base units.{% enddocs %}

{% docs jdawms__abccod %}ABC velocity classification code.{% enddocs %}

{% docs jdawms__app_catch_qty %}Quantity field: app_catch_qty.{% enddocs %}

{% docs jdawms__appqty %}Applied/confirmed quantity.{% enddocs %}

{% docs jdawms__arc_src %}WMS arc_src attribute.{% enddocs %}

{% docs jdawms__arcdte %}Date/time field: arcdte.{% enddocs %}

{% docs jdawms__arecod %}Area code — logical warehouse area/zone the location belongs to.{% enddocs %}

{% docs jdawms__carcod %}Carrier code.{% enddocs %}

{% docs jdawms__dst_mov_zone_id %}Code/identifier: dst_mov_zone_id.{% enddocs %}

{% docs jdawms__expire_dte %}Expiration date of the stock.{% enddocs %}

{% docs jdawms__inv_attr_dte1 %}User-defined inventory attribute: inv_attr_dte1.{% enddocs %}

{% docs jdawms__inv_attr_dte2 %}User-defined inventory attribute: inv_attr_dte2.{% enddocs %}

{% docs jdawms__inv_attr_flt1 %}User-defined inventory attribute: inv_attr_flt1.{% enddocs %}

{% docs jdawms__inv_attr_flt2 %}User-defined inventory attribute: inv_attr_flt2.{% enddocs %}

{% docs jdawms__inv_attr_flt3 %}User-defined inventory attribute: inv_attr_flt3.{% enddocs %}

{% docs jdawms__inv_attr_int1 %}User-defined inventory attribute: inv_attr_int1.{% enddocs %}

{% docs jdawms__inv_attr_int2 %}User-defined inventory attribute: inv_attr_int2.{% enddocs %}

{% docs jdawms__inv_attr_int3 %}User-defined inventory attribute: inv_attr_int3.{% enddocs %}

{% docs jdawms__inv_attr_int4 %}User-defined inventory attribute: inv_attr_int4.{% enddocs %}

{% docs jdawms__inv_attr_int5 %}User-defined inventory attribute: inv_attr_int5.{% enddocs %}

{% docs jdawms__inv_attr_str1 %}User-defined inventory string attribute 1 (inv_attr_str1).{% enddocs %}

{% docs jdawms__inv_attr_str10 %}User-defined inventory string attribute 0 (inv_attr_str10).{% enddocs %}

{% docs jdawms__inv_attr_str11 %}User-defined inventory string attribute 1 (inv_attr_str11).{% enddocs %}

{% docs jdawms__inv_attr_str12 %}User-defined inventory string attribute 2 (inv_attr_str12).{% enddocs %}

{% docs jdawms__inv_attr_str13 %}User-defined inventory string attribute 3 (inv_attr_str13).{% enddocs %}

{% docs jdawms__inv_attr_str14 %}User-defined inventory string attribute 4 (inv_attr_str14).{% enddocs %}

{% docs jdawms__inv_attr_str15 %}User-defined inventory string attribute 5 (inv_attr_str15).{% enddocs %}

{% docs jdawms__inv_attr_str16 %}User-defined inventory string attribute 6 (inv_attr_str16).{% enddocs %}

{% docs jdawms__inv_attr_str17 %}User-defined inventory string attribute 7 (inv_attr_str17).{% enddocs %}

{% docs jdawms__inv_attr_str18 %}User-defined inventory string attribute 8 (inv_attr_str18).{% enddocs %}

{% docs jdawms__inv_attr_str2 %}User-defined inventory string attribute 2 (inv_attr_str2).{% enddocs %}

{% docs jdawms__inv_attr_str3 %}User-defined inventory string attribute 3 (inv_attr_str3).{% enddocs %}

{% docs jdawms__inv_attr_str4 %}User-defined inventory string attribute 4 (inv_attr_str4).{% enddocs %}

{% docs jdawms__inv_attr_str5 %}User-defined inventory string attribute 5 (inv_attr_str5).{% enddocs %}

{% docs jdawms__inv_attr_str6 %}User-defined inventory string attribute 6 (inv_attr_str6).{% enddocs %}

{% docs jdawms__inv_attr_str7 %}User-defined inventory string attribute 7 (inv_attr_str7).{% enddocs %}

{% docs jdawms__inv_attr_str8 %}User-defined inventory string attribute 8 (inv_attr_str8).{% enddocs %}

{% docs jdawms__inv_attr_str9 %}User-defined inventory string attribute 9 (inv_attr_str9).{% enddocs %}

{% docs jdawms__lm_assign_num %}Code/identifier: lm_assign_num.{% enddocs %}

{% docs jdawms__lm_assign_seqnum %}Code/identifier: lm_assign_seqnum.{% enddocs %}

{% docs jdawms__load_attr1_flg %}Flag (0/1): load_attr1_flg.{% enddocs %}

{% docs jdawms__load_attr2_flg %}Flag (0/1): load_attr2_flg.{% enddocs %}

{% docs jdawms__load_attr3_flg %}Flag (0/1): load_attr3_flg.{% enddocs %}

{% docs jdawms__load_attr4_flg %}Flag (0/1): load_attr4_flg.{% enddocs %}

{% docs jdawms__load_attr5_flg %}Flag (0/1): load_attr5_flg.{% enddocs %}

{% docs jdawms__lodtag %}WMS lodtag attribute.{% enddocs %}

{% docs jdawms__loducc %}WMS loducc attribute.{% enddocs %}

{% docs jdawms__lotflg %}Flag (0/1): lotflg.{% enddocs %}

{% docs jdawms__lotnum %}Lot/batch number.{% enddocs %}

{% docs jdawms__mov_zone_id %}Movement zone identifier.{% enddocs %}

{% docs jdawms__ordlin %}Order line number.{% enddocs %}

{% docs jdawms__ordsln %}Order sub-line number.{% enddocs %}

{% docs jdawms__orgcod %}Country/origin code of the goods.{% enddocs %}

{% docs jdawms__orgflg %}Flag (0/1): orgflg.{% enddocs %}

{% docs jdawms__prmflg %}Flag (0/1): prmflg.{% enddocs %}

{% docs jdawms__prtdte %}Date/time field: prtdte.{% enddocs %}

{% docs jdawms__revflg %}Flag (0/1): revflg.{% enddocs %}

{% docs jdawms__revlvl %}Revision level of the part.{% enddocs %}

{% docs jdawms__srvlvl %}Carrier service level.{% enddocs %}

{% docs jdawms__subtag %}WMS subtag attribute.{% enddocs %}

{% docs jdawms__subucc %}WMS subucc attribute.{% enddocs %}

{% docs jdawms__sup_lot_flg %}Flag (0/1): sup_lot_flg.{% enddocs %}

{% docs jdawms__sup_lotnum %}Supplier lot number.{% enddocs %}

{% docs jdawms__supnum %}Supplier number.{% enddocs %}

{% docs jdawms__uccdte %}Date/time field: uccdte.{% enddocs %}

{% docs jdawms__untpal %}Units per pallet.{% enddocs %}

{% docs jdawms__uomcod %}Unit-of-measure code.{% enddocs %}

{% docs jdawms__velzon %}Velocity zone.{% enddocs %}

{% docs jdawms__wkonum %}Code/identifier: wkonum.{% enddocs %}

{% docs jdawms__wkorev %}WMS wkorev attribute.{% enddocs %}

{% docs jdawms__wrkref_dtl %}Pick-work detail (task line) identifier.{% enddocs %}

{% docs jdawms__wrktyp %}Work type code.{% enddocs %}
