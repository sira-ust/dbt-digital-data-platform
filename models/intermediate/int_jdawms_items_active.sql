-- int_jdawms_items_active — int_jdawms_items filtered to ACTIVE items only:
-- prtnum has at least one 'A' (active) row in invsum. prtmst/prtdsc carry
-- every item ever set up (~5.7k); invsum only carries items currently
-- tracked in the warehouse, so this is the "do we actually still sell/stock
-- this" filter. Matched on prtnum ONLY (invsum's prt_client_id is not
-- joined) per explicit direction — invsum doesn't reliably carry the same
-- client-id grain as prtmst/prtdsc.
--
-- Not folded into int_jdawms_items itself: that model is documented as the
-- generic, unfiltered item spine other marts rely on (including historical/
-- inactive items on purpose). This is a narrower, business-filtered view for
-- consumers that specifically need "sellable today" — e.g. the social
-- concept->SKU resolver, so it never proposes a discontinued item.
--
-- Materialized as a view: filters a small (~5.7k row) view by a semi-join,
-- recompute cost is near zero.

{{ config(materialized='view') }}

with items as (

    select * from {{ ref('int_jdawms_items') }}

),

active_prtnums as (

    -- stg_jdawms__invsum already trims prtnum; no need to re-trim here
    select distinct prtnum
    from {{ ref('stg_jdawms__invsum') }}
    where invsts = 'A'

)

select i.*
from items as i
inner join active_prtnums as a
    on a.prtnum = i.prtnum
