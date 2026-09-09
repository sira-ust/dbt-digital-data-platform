-- dim_rep_logins — one row per LOGIN, keyed on username. The table an
-- authenticated app hits FIRST: "this person just signed in, whose data is
-- theirs?"
--
-- WHY IT IS SEPARATE FROM dim_reps. A territory code can hold more than one
-- login, so login and rep are different grains, and collapsing them into one
-- table means every consumer has to remember a filter to avoid fan-out.
-- mart_rep_customer_activity already works around this with
-- `max(first_name || ' ' || last_name) group by salesperson_code` — a guard that
-- silently picks a name rather than admitting there are two. Split by grain,
-- each join is unambiguous:
--
--   login -> rep    join dim_rep_logins on username     (many-to-one, always safe)
--   rep   -> name   join dim_reps       on sales_code   (one-to-one, always safe)
--
-- Never join dim_rep_logins to a metric table on sales_code: that is
-- one-to-many and will multiply the metric by the rep's login count.
--
-- ADMINS ARE INCLUDED, with sales_code null and is_salesperson false. An admin
-- signing in is a real, expected event and the caller has to be able to tell
-- "this person has no territory" from "this person is unknown" — returning no
-- row at all conflates the two.

with users as (

    select * from {{ ref('stg_mysql__admin_users') }}

),

ranked as (

    select
        *,
        -- Which login speaks for the rep when something has to pick one. Active
        -- first, then most recently used, then the lowest user_id as a
        -- deterministic tie-break so the answer does not move between runs.
        -- ORDER MATTERS: a dormant-but-newer login must not outrank the one the
        -- rep actually signs in with.
        row_number() over (
            partition by salesperson_code
            order by
                case when coalesce(is_active, 0) = 1 then 0 else 1 end,
                logdate desc nulls last,
                user_id
        )                                                                as _login_rank
    from users
    where salesperson_code is not null

)

select
    u.username,
    u.user_id,
    u.email,
    u.first_name,
    u.last_name,
    -- one display string, built once. Falls back through the parts rather than
    -- concatenating a null into "Jane NULL".
    coalesce(
        nullif(trim(coalesce(u.first_name, '') || ' ' || coalesce(u.last_name, '')), ''),
        u.username
    )                                                                    as rep_name,

    -- the territory code every rep mart is keyed on. NULL for an admin.
    u.salesperson_code                                                   as sales_code,

    u.role_name,
    (coalesce(u.is_active, 0) = 1)                                       as is_active,
    (coalesce(u.is_salesperson, 0) = 1)                                  as is_salesperson,

    -- true for exactly one login per sales_code. An admin has no territory and
    -- so is never ranked; coalesce makes that FALSE rather than null, because a
    -- null here would drop the row from `where is_primary_login` and from
    -- `where not is_primary_login` alike, hiding admins from both.
    coalesce(r._login_rank = 1, false)                                   as is_primary_login,

    -- lifetime sign-in count and last sign-in, straight from admin_users. Useful
    -- for deciding whether a second login on a territory is live or abandoned.
    u.lognum                                                             as login_count,
    u.logdate                                                            as last_login_at,
    u.interface_locale,
    u.created_at
from users as u
left join ranked as r
    on r.user_id = u.user_id
