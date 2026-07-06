-- Staging for jdawms.prtdsc — 1:1 lossless view over the raw WMS replica.
-- All 6 source columns preserved as-is (types already clean in Delta).
-- Databricks-only (no local sample); materialized as a view (see dbt_project.yml).

with source as (
    select * from {{ source('jdawms', 'prtdsc') }}
)

select
    colnam,
    colval,
    locale_id,
    lngdsc,
    short_dsc,
    loaddate
from source
