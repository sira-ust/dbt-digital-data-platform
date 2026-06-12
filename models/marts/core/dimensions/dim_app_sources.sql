select
    source_code,
    app_name,
    app_full_name,
    user_type,
    platform
from {{ ref('seed_app_sources') }}
