-- Sales rep activity events enriched with session context and user master data.
-- Event grain — one row per user_activity_report_event.
-- Session metadata is joined from user_activity_report; user full name and
-- role are joined from admin_users (left join — works before MySQL arrives,
-- enriches automatically once admin_users data is available).

with events as (

    select * from {{ ref('stg_mysql__user_activity_report_event') }}

),

sessions as (

    select * from {{ ref('stg_mysql__user_activity_report') }}

),

users as (

    select * from {{ ref('stg_mysql__admin_users') }}

)

select
    -- ── event identifiers ───────────────────────────────────────────────
    e.entity_id,
    e.session_entity_id,
    e.username,
    e.sales_code,

    -- ── user context (from admin_users — null until MySQL connected) ────
    u.firstname,
    u.lastname,
    u.full_name,
    u.role_name,
    u.is_active                                     as user_is_active,

    -- ── session context (from parent user_activity_report) ─────────────
    s.display_name,
    s.device_model,
    s.app_version                                   as session_app_version,
    s.version_major,
    s.version_minor,
    s.version_build,
    s.session_id,
    s.started_at                                    as session_started_at,
    s.ended_at                                      as session_ended_at,
    s.event_count                                   as session_event_count,
    s.is_voluntary_exit,
    s.latitude                                      as session_latitude,
    s.longitude                                     as session_longitude,
    s.sales_name,

    -- ── event classification ────────────────────────────────────────────
    e.activity_type_code,
    e.title,

    -- ── event timing ────────────────────────────────────────────────────
    e.started_at,
    e.ended_at,
    e.device_timezone,

    -- ── event location ──────────────────────────────────────────────────
    e.latitude,
    e.longitude,

    -- ── customer context ────────────────────────────────────────────────
    e.customer_id,
    e.keyword,
    e.category,
    e.sku,
    e.qty,
    e.visits_num,

    -- ── device state ────────────────────────────────────────────────────
    e.is_wifi,
    e.battery_pct,
    e.device_space,
    e.app_version                                   as event_app_version,

    -- ── flags ──────────────────────────────────────────────────────────
    e.is_done,
    e.is_login,

    -- ── payload ─────────────────────────────────────────────────────────
    e.response,
    e.method_code,

    -- ── server timestamps ───────────────────────────────────────────────
    e.updated_at_server

from events as e
left join sessions as s
    on e.session_entity_id = s.entity_id
left join users as u
    on e.username = u.username
