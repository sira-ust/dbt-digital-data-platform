-- int_jdawms_items — the WMS item master made readable, one row per item
-- (prtnum + prt_client_id). prtmst attributes + English names from prtdsc +
-- decoded ABC class from seed_jdawms_code_descriptions (this model is the
-- seed's first consumer). Generic: no filters, no business logic — this is
-- the item spine for every SKU-level mart and the future dim_items surface
-- for Unity Catalog / Genie.
--
-- prtmst carries two template rows per item (wh_id_tmpl '----' default and
-- 'CABOT' override); the CABOT override wins, same convention as the seed.
-- prtdsc keys descriptions as colval 'prtnum|prt_client_id|wh_id_tmpl'
-- (colnam sometimes carries a UTF-8 BOM, hence the LIKE match); US_ENGLISH
-- locale only, CABOT override preferred.
--
-- Verified 2026-07-13: prtnum = dsp_prtnum = the app-side sku (99.9%).
--
-- Materialized as a VIEW (overrides the intermediate table default): ~5.7k
-- items, joins over small staging views — recompute cost is near zero.

{{ config(materialized='view') }}

with prtmst_ranked as (

    select
        *,
        row_number() over (
            partition by prtnum, prt_client_id
            order by case when wh_id_tmpl = 'CABOT' then 0 else 1 end
        )                                                               as _rn
    from {{ ref('stg_jdawms__prtmst') }}

),

items as (

    select * from prtmst_ranked where _rn = 1

),

descriptions as (

    -- colval is pipe-delimited; split_part works identically on DuckDB and
    -- Databricks (same guarantee the response_part macro relies on)
    select
        nullif(trim(split_part(colval, '|', 1)), '')                    as prtnum,
        nullif(trim(split_part(colval, '|', 2)), '')                    as prt_client_id,
        lngdsc,
        short_dsc,
        row_number() over (
            partition by split_part(colval, '|', 1),
                         split_part(colval, '|', 2)
            order by case when split_part(colval, '|', 3) = 'CABOT'
                          then 0 else 1 end
        )                                                               as _rn
    from {{ ref('stg_jdawms__prtdsc') }}
    where colnam like '%prtnum|prt_client_id|wh_id_tmpl'
      and locale_id = 'US_ENGLISH'

),

abc_codes as (

    select code_value, long_description
    from {{ ref('seed_jdawms_code_descriptions') }}
    where code_domain = 'abccod'

)

select
    i.prtnum,
    i.prt_client_id,
    i.dsp_prtnum,
    d.lngdsc                                                            as item_name,
    d.short_dsc                                                         as item_short_name,
    i.prtfam                                                            as item_family,
    i.abccod                                                            as abc_class,
    abc.long_description                                                as abc_class_description,
    i.velzon                                                            as velocity_zone,
    i.stkuom                                                            as stock_uom,
    i.dspuom                                                            as display_uom,
    i.rcvsts                                                            as receive_status
from items as i
left join descriptions as d
    on d.prtnum = i.prtnum
   and d.prt_client_id = i.prt_client_id
   and d._rn = 1
left join abc_codes as abc
    on abc.code_value = i.abccod
