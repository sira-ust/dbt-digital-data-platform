select
    category_id,
    category_name
from {{ ref('seed_categories') }}
