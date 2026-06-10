-- assert_sales_agents_have_sales_code
--
-- Sales app events (PDA-A, CatalogFS-I, CatalogFS-A) should always carry a
-- sales_code — it identifies the territory/team the agent belongs to.
-- A null sales_code on a sales app suggests a misconfigured device or a
-- test account that slipped into production data.
--
-- Fails (returns rows) if any sales-app event has a null or empty sales_code.
-- Severity: warn — investigation needed but pipeline should not be blocked.

{{ config(severity='warn') }}

select
    entity_id,
    source_code,
    username,
    sales_code,
    created_at_utc
from {{ ref('stg_mysql__system_events') }}
where source_code in ('PDA-A', 'CatalogFS-I', 'CatalogFS-A')
  and (sales_code is null or trim(sales_code) = '')
