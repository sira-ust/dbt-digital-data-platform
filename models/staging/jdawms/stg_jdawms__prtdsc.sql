-- Staging for jdawms.prtdsc — 1:1 lossless view over the raw WMS replica.
-- All 6 source columns preserved as-is (types already clean in Delta).
-- Databricks reads the real replica; DuckDB reads mock parquet (see data/README.md).

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
