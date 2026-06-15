-- fct_customer_events — one row per customer app event.
-- Event grain from int_customer_tracking_enriched; exposes all event and
-- session context for BI drill-down and chatbot queries.

select * from {{ ref('int_customer_tracking_enriched') }}
