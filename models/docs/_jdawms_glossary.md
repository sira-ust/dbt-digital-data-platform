{# ---------------------------------------------------------------------------
   Shared column definitions for the jdawms (JDA/Blue Yonder WMS) source.

   AUTO-GENERATED from seeds/seed_jdawms_data_dictionary.csv by
   scripts/generate_jdawms_glossary.py -- do not edit by hand. To change a
   definition, edit the seed (or the WMS data dictionary it came from) and
   re-run the script.

   Definitions are deduplicated by MEANING: a (column, text) pair used by 2+
   tables becomes one block here; table-specific meanings stay inline in
   _jdawms__sources.yml. Variant blocks are suffixed with a table name, e.g.
   jdawms__ins_dt__pckwrk_dtl.

   Blocks under "pipeline / carried-over" are not in the data dictionary
   (ingestion columns etc.) and are preserved from the previous glossary.
--------------------------------------------------------------------------- #}

{# pckwrk_dtl, pckwrk_hdr #}
{% docs jdawms__app_catch_qty %}Applied Catch Quantity — The catch quantity already applied.{% enddocs %}

{# pckwrk_dtl, pckwrk_hdr #}
{% docs jdawms__appqty %}Applied Quantity — The amount of product applied against this pick.{% enddocs %}

{# pckwrk_dtl, pckwrk_hdr #}
{% docs jdawms__client_id %}Client ID.{% enddocs %}

{# dlytrn, pckwrk_hdr #}
{% docs jdawms__devcod %}Device Code — The device code that should be used when printing labels for this pick.{% enddocs %}

{# invlod, pckwrk_hdr #}
{% docs jdawms__est_time %}Estimated Goal Time — Labor Estimate (Seconds).{% enddocs %}

{# pckwrk_hdr, prtftp #}
{% docs jdawms__ftpcod %}Footprint Code — This is footprint code associate with the item.{% enddocs %}

{# dlytrn, inv_snap, invlod, invsub, invsum, locmst, prtftp, prtftp_dtl #}
{% docs jdawms__ins_dt %}Inserted Date — The date the row was inserted.{% enddocs %}

{# pckwrk_dtl, pckwrk_hdr #}
{% docs jdawms__ins_dt__pckwrk_dtl %}Inserted Date — Date the row was inserted.{% enddocs %}

{# dlytrn, inv_snap, invlod, invsub, invsum, locmst, prtftp, prtftp_dtl #}
{% docs jdawms__ins_user_id %}Inserted User — The user id of the person who created the row.{% enddocs %}

{# pckwrk_dtl, pckwrk_hdr #}
{% docs jdawms__ins_user_id__pckwrk_dtl %}Inserted User — User id of the person who created the row.{% enddocs %}

{# dlytrn, inv_snap, invlod, invsub, invsum, locmst #}
{% docs jdawms__last_upd_dt %}Last Updated Date — The date the row was last updated.{% enddocs %}

{# pckwrk_dtl, pckwrk_hdr #}
{% docs jdawms__last_upd_dt__pckwrk_dtl %}Last Updated Date — Date the row was last updated.{% enddocs %}

{# prtftp, prtftp_dtl #}
{% docs jdawms__last_upd_dt__prtftp %}Last Updated Date — The date the row as was last updated.{% enddocs %}

{# dlytrn, inv_snap, invlod, invsub, invsum, locmst, pckwrk_dtl, pckwrk_hdr, prtftp, prtftp_dtl #}
{% docs jdawms__last_upd_user_id %}Last Updated User — The user id of the person who updated the row most recently.{% enddocs %}

{# pckwrk_dtl, pckwrk_hdr #}
{% docs jdawms__lm_assign_num %}Labor Assignment Number.{% enddocs %}

{# pckwrk_dtl, pckwrk_hdr #}
{% docs jdawms__lm_assign_seqnum %}Labor Assignment Sequence Number.{% enddocs %}

{# dlytrn, invlod #}
{% docs jdawms__load_attr1_flg %}Wrapped — The first load attribute. A load attribute is a configurable flag field to indicate attributes of a load such as the load being wrapped.{% enddocs %}

{# dlytrn, invlod #}
{% docs jdawms__load_attr2_flg %}Load Attribute 2 — The second load attribute. A load attribute is a configurable flag field to indicate attributes of a load such as the load being wrapped.{% enddocs %}

{# dlytrn, invlod #}
{% docs jdawms__load_attr3_flg %}Load Attribute 3 — The third load attribute. A load attribute is a configurable flag field to indicate attributes of a load such as the load being wrapped.{% enddocs %}

{# dlytrn, invlod #}
{% docs jdawms__load_attr4_flg %}Load Attribute 4 — The fourth load attribute. A load attribute is a configurable flag field to indicate attributes of a load such as the load being wrapped.{% enddocs %}

{# dlytrn, invlod #}
{% docs jdawms__load_attr5_flg %}Load Attribute 5 — The fifth load attribute. A load attribute is a configurable flag field to indicate attributes of a load such as the load being wrapped.{% enddocs %}

{# pckwrk_dtl, pckwrk_hdr #}
{% docs jdawms__lodlvl %}LPN Level — The type of pick: L = Pallet pick, S = case pick, D = piece pick.{% enddocs %}

{# dlytrn, invlod #}
{% docs jdawms__lodnum %}LPN — Uniquely identifies invlod record. In many systems, this value is the same as the label on a pallet.{% enddocs %}

{# shipment, shipment_line #}
{% docs jdawms__mod_usr_id %}Modified by — Last Modified By.{% enddocs %}

{# shipment, shipment_line #}
{% docs jdawms__moddte %}Date Last Modified.{% enddocs %}

{# pckwrk_dtl, pckwrk_hdr #}
{% docs jdawms__pck_catch_qty %}Pick Catch Quantity — The catch quantity to pick.{% enddocs %}

{# pckwrk_dtl, pckwrk_hdr #}
{% docs jdawms__pckqty %}Pick Quantity — The amount of product to pick.{% enddocs %}

{# invlod, invsub #}
{% docs jdawms__prmflg %}Permanent Load/Sub — Set if this is a 'permanent' subload. Permanent subloads are used throughout the system when it is necessary to provide a container to attach details to. Additionally, in systems utilizing totes, they are represented as 'perm subloads'.{% enddocs %}

{# dlytrn, invsum, prtmst #}
{% docs jdawms__prt_client_id %}Item Client ID — The client which owns the item number.{% enddocs %}

{# inv_snap, prtftp_dtl #}
{% docs jdawms__prt_client_id__inv_snap %}Item Client ID.{% enddocs %}

{# pckwrk_dtl, pckwrk_hdr #}
{% docs jdawms__prt_client_id__pckwrk_dtl %}Item Client ID — Client id of item number. In non-3PL systems, this will be set to a default of '----'.{% enddocs %}

{# pckwrk_dtl, pckwrk_hdr #}
{% docs jdawms__prtdte %}Print Date — Date pick was printed.{% enddocs %}

{# pckwrk_dtl, pckwrk_hdr, shipment_line #}
{% docs jdawms__prtnum %}Item Number - Identifier for the item, or SKU that is ordered.{% enddocs %}

{# dlytrn, prtmst #}
{% docs jdawms__prtnum__dlytrn %}Item Number — Also referred to as item number or SKU.{% enddocs %}

{# inv_snap, prtftp_dtl #}
{% docs jdawms__prtnum__inv_snap %}Item Number.{% enddocs %}

{# pckwrk_dtl, pckwrk_hdr #}
{% docs jdawms__schbat %}Schedule Batch Number — Schedule batch. This uniquely identifies the record and represents a group of picks.{% enddocs %}

{# dlytrn, invsub #}
{% docs jdawms__subnum %}Sub-LPN — Uniquely identified invsub record.{% enddocs %}

{# dlytrn, inv_snap, invlod, invsub, invsum, locmst #}
{% docs jdawms__u_version %}Version — The version number.{% enddocs %}

{# invlod, invsub #}
{% docs jdawms__uccdte %}UCC Date — The date/time the UCC128 shipping label was applied.{% enddocs %}

{# pckwrk_dtl, pckwrk_hdr #}
{% docs jdawms__untcas %}Units per case.{% enddocs %}

{# invlod, pckwrk_dtl, pckwrk_hdr #}
{% docs jdawms__wh_id %}Warehouse ID - the warehouse in which the inventory is to be received.{% enddocs %}

{# inv_snap, prtftp_dtl #}
{% docs jdawms__wh_id__inv_snap %}Warehouse ID.{% enddocs %}

{# invsum, shipment #}
{% docs jdawms__wh_id__invsum %}Warehouse Id.{% enddocs %}

{# pckwrk_dtl, shipment_line #}
{% docs jdawms__wkorev %}Work Order Revision.{% enddocs %}

{# pckwrk_dtl, pckwrk_hdr #}
{% docs jdawms__wrktyp %}Work type.{% enddocs %}

{# ---- pipeline / carried-over (not in the data dictionary) ---- #}

{% docs jdawms___rescued_data %}Auto Loader rescued-data column — captures values that did not fit the schema on ingest; normally null.{% enddocs %}

{% docs jdawms__adddte %}Timestamp the record was created/added.{% enddocs %}

{% docs jdawms__dtlnum %}Inventory detail number (innermost unit).{% enddocs %}

{% docs jdawms__loaddate %}Ingestion timestamp — when this row was loaded into the lakehouse (pipeline watermark, not a business field).{% enddocs %}

{% docs jdawms__rowid %}Source database internal row identifier.{% enddocs %}

{% docs jdawms__untpal %}Units per pallet.{% enddocs %}
