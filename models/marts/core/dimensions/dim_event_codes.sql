select
    description_code,
    function_name,
    l1_category_name,
    payload_format,
    has_geo,
    is_system_event,
    event_type,
    log_level,
    platforms
from {{ ref('seed_event_codes') }}
