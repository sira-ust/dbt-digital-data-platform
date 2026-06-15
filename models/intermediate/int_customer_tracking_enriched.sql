-- Customer tracking events enriched with their parent session context.
-- Event grain — one row per tracking_report_event.
-- Session metadata (device, version, customer name) is joined from
-- tracking_report so downstream marts don't need to repeat the join.

with events as (

    select * from {{ ref('stg_mysql__tracking_report_event') }}

),

sessions as (

    select * from {{ ref('stg_mysql__tracking_report') }}

)

select
    -- ── event identifiers ───────────────────────────────────────────────
    e.entity_id,
    e.session_entity_id,
    e.customer_id,

    -- ── session context (from parent tracking_report) ───────────────────
    s.customer_name,
    s.device_model,
    s.app_version,
    s.version_major,
    s.version_minor,
    s.version_build,
    s.session_id,
    s.started_at                                    as session_started_at,
    s.ended_at                                      as session_ended_at,
    s.total_events                                  as session_total_events,

    -- ── event classification ────────────────────────────────────────────
    e.event_type_code,
    e.event_type_label,
    e.title,
    e.page,
    e.method_code,

    -- ── event timing ────────────────────────────────────────────────────
    e.started_at,
    e.ended_at,
    e.device_timezone,
    e.duration_seconds,

    -- ── product context ─────────────────────────────────────────────────
    e.item_no,
    e.sku,
    e.qty,
    e.quote_id,
    e.categories_name,
    e.keyword,

    -- ── additional context ──────────────────────────────────────────────
    e.notes,
    e.address,
    e.source,
    e.icon,
    e.app_version                                   as event_app_version,

    -- ── server timestamps ───────────────────────────────────────────────
    e.created_at_server,
    e.updated_at_server

from events as e
left join sessions as s
    on e.session_entity_id = s.entity_id
