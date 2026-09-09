-- dim_reps — one row per SALES TERRITORY CODE. The rep as an analytical entity:
-- safe to join to any rep mart on sales_code without fan-out, which is the
-- whole reason it exists (see dim_rep_logins for the login grain).
--
-- SPINE is the union of the two places a territory code can be declared:
--   admin_users.salesperson_code  a person who can sign in
--   nav customer.salesperson_code a person who owns accounts
-- Neither alone is complete. A newly issued code can own accounts before its
-- login is created, and a departed rep's login can outlive the reassignment of
-- their book. Publishing has_login / owns_accounts says which case a row is
-- rather than quietly dropping it.
--
-- Event sales_codes are deliberately NOT part of the spine. A code appearing on
-- events but in neither source is a data-quality fault, and inventing a dim row
-- for it would hide that; the rep marts left-join here, so such a rep still
-- gets its rows with a null name, which is the visible shape.

with logins as (

    select * from {{ ref('dim_rep_logins') }}
    where sales_code is not null

),

accounts as (

    select
        salesperson_code                                                 as sales_code,
        count(*)                                                         as accounts_owned,
        sum(case when is_active then 1 else 0 end)                       as accounts_owned_active
    from {{ ref('stg_nav__customers') }}
    where salesperson_code is not null
      and not {{ is_test_customer('customer_key') }}
    group by salesperson_code

),

login_rollup as (

    select
        sales_code,
        count(*)                                                         as login_count,
        sum(case when is_active then 1 else 0 end)                       as active_login_count,
        {{ sort_array('array_agg(username)') }}                          as usernames,
        max(last_login_at)                                               as last_login_at,
        -- the primary login's own fields, picked by is_primary_login rather than
        -- by max() over the group: max() on a name returns whichever string sorts
        -- highest, which is not a person's identity, and was how a rep with two
        -- logins could be displayed under the wrong name.
        max(case when is_primary_login then username  end)               as primary_username,
        max(case when is_primary_login then rep_name  end)               as rep_name,
        max(case when is_primary_login then email     end)               as primary_email,
        max(case when is_primary_login then role_name end)               as role_name
    from logins
    group by sales_code

),

spine as (

    select sales_code from login_rollup
    union
    select sales_code from accounts

)

select
    s.sales_code,
    l.rep_name,
    l.primary_username,
    l.primary_email,
    l.role_name,

    -- >1 means this territory has several logins. Any per-login analysis has to
    -- go through dim_rep_logins; joining THAT table on sales_code to a metric
    -- would multiply the metric by this number.
    coalesce(l.login_count, 0)                                           as login_count,
    coalesce(l.active_login_count, 0)                                    as active_login_count,
    l.usernames,
    l.last_login_at,

    -- how big the rep's book is, test/internal accounts excluded. accounts_owned
    -- counts every account NAV assigns them; _active drops the 48% of the
    -- customer master flagged inactive. Both are published because "my accounts"
    -- means the active ones to a rep and all of them to a manager.
    coalesce(a.accounts_owned, 0)                                        as accounts_owned,
    coalesce(a.accounts_owned_active, 0)                                 as accounts_owned_active,

    -- which source declared this code. A row with owns_accounts and no login is
    -- a book with nobody able to sign in for it; a row with a login and no
    -- accounts is a rep whose book has not been assigned (or was reassigned).
    (l.sales_code is not null)                                           as has_login,
    (a.sales_code is not null)                                           as owns_accounts,
    coalesce(l.active_login_count, 0) > 0                                as is_active
from spine as s
left join login_rollup as l on l.sales_code = s.sales_code
left join accounts     as a on a.sales_code = s.sales_code
