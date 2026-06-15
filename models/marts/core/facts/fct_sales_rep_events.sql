-- fct_sales_rep_events — one row per sales rep activity event.
-- Event grain from int_user_activity_enriched; exposes all event, session,
-- and user context for BI drill-down and chatbot queries.

select * from {{ ref('int_user_activity_enriched') }}
