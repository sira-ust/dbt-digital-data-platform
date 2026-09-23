-- stg_nav__promotion_lines — items on promotion, one row per promotion line.
-- The source for the "promo item that fits their store" half of the
-- recommendation marts.
--
-- DOES NOT JOIN TO promotion_header, and that is the whole design decision.
-- promotion_line carries TWO promotion codes — promotion_code ([Promotion Code])
-- and promo_code ([Promo Code]) — and the source docs say these are genuinely
-- distinct NAV fields, not an ingestion artefact, with only one of them the real
-- join to the header's [Code]. Nobody has resolved which. Joining on a guess
-- would either drop live promotions or attach the wrong name and window to them,
-- and a promotion silently carrying another promotion's dates is worse than one
-- with no name at all.
--
-- So this model uses the LINE'S OWN promo_begin_date / promo_end_date, which are
-- present on every row and which the source docs warn "may differ from the
-- header window — check before assuming the header governs". Using the line
-- window is both the safer reading and the one that needs no header join. Both
-- codes are carried through unrenamed so that whoever resolves the question can
-- join without re-staging.
--
-- The consequence, stated plainly: promotions here have a window and an item but
-- NO NAME. A voice agent can say "this is on promotion until the 30th"; it
-- cannot say which promotion. That is a real gap and it closes the moment the
-- dev team confirms the join key.
--
-- LIFECYCLE IS A DOUBLE GATE. released and discontinued are separate NAV flags,
-- so an item is actually on offer only when it is released AND not
-- discontinued — either one alone admits lines that are not live.
--
-- THE DEV MOCK REPRODUCES THE SOURCE'S DEFECTS ON PURPOSE. sprice is zero on
-- ~97% of generated lines and the buy/free pair is set on ~31%, matching what
-- NAV actually holds — so the "treat 0 as not set" path is exercised locally
-- rather than only discovered in production.

with source as (

    select * from {{ source('nav', 'promotion_line') }}

)

select
    -- BOTH codes, unrenamed. See the header — which one joins to
    -- promotion_header.promo_code is unresolved, and the names are the only clue
    -- carried forward.
    nullif(trim(cast(promotion_code as {{ dbt.type_string() }})), '')      as promotion_code,
    nullif(trim(cast(promo_code     as {{ dbt.type_string() }})), '')      as promo_code,

    nullif(trim(cast(item_no as {{ dbt.type_string() }})), '')             as item_no,
    nullif(trim(cast(promotion_group_code as {{ dbt.type_string() }})), '')
                                                                           as promotion_group_code,

    -- the LINE's window, not the header's. Cast to date: NAV means a day, and
    -- the time component is an export artefact.
    cast(promo_begin_date as date)                                         as promo_begin_date,
    cast(promo_end_date   as date)                                         as promo_end_date,

    -- ── the offer ─────────────────────────────────────────────────────────
    -- SPRICE IS NULLED AT ZERO, and that is not tidying. NAV holds 0 on 12,606
    -- of 12,967 lines and on ALL 86 promotions live today (measured
    -- 2026-09-23), so 0 means NOT SET. Carried through as a number it would
    -- read as "this item is free", which is the one thing a rep must never be
    -- told.
    nullif(cast(sprice as {{ dbt.type_numeric() }}), 0)                    as promo_price,
    -- The mechanic that IS maintained: 27 of those 86 live lines carry a
    -- buy-X-get-Y-free pair. This, not the price, is what makes a promotion
    -- worth mentioning.
    nullif(cast(promo_buy_qty  as {{ dbt.type_numeric() }}), 0)            as promo_buy_qty,
    nullif(cast(promo_free_qty as {{ dbt.type_numeric() }}), 0)            as promo_free_qty,
    (   coalesce(cast(promo_buy_qty  as {{ dbt.type_numeric() }}), 0) > 0
    and coalesce(cast(promo_free_qty as {{ dbt.type_numeric() }}), 0) > 0) as has_promo_offer,

    cast(campaign_target_qty as {{ dbt.type_numeric() }})                  as campaign_target_qty,
    (coalesce(cast(new_on_promotion as {{ dbt.type_int() }}), 0) = 1)      as is_new_on_promotion,

    -- the two lifecycle flags, kept separate AND combined. Separate so a
    -- consumer can see which one excluded a line; combined so no consumer has to
    -- remember that both matter.
    (coalesce(cast(released as {{ dbt.type_int() }}), 0) = 1)              as is_released,
    (coalesce(cast(discontinued as {{ dbt.type_int() }}), 0) = 1)          as is_discontinued,
    (       coalesce(cast(released     as {{ dbt.type_int() }}), 0) = 1
        and coalesce(cast(discontinued as {{ dbt.type_int() }}), 0) = 0)   as is_live_promo_line,

    nullif(trim(cast(holiday_occasion as {{ dbt.type_string() }})), '')    as holiday_occasion,
    cast(holiday_year as {{ dbt.type_int() }})                             as holiday_year,

    cast(loaddate as timestamp)                                            as loaded_at
from source
where item_no is not null
