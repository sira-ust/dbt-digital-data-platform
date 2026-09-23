{{ config(materialized='table') }}

-- mart_account_item_opportunities — THE PITCH LIST. One row per account per
-- candidate item, ranked, capped at var('account_item_opportunity_top_n').
-- "What are the 5-10 items I should walk in and talk about?"
--
--   Account | Item | Why | Evidence | In stock | Rank
--
-- ═══ EVERY ROW CARRIES ITS OWN REASON, AND THE EVIDENCE FOR IT ═════════════
-- opportunity_reason says WHY the item is on the list and opportunity_evidence
-- is the fact behind it, already phrased for a person ("bought 7 times, last 68
-- days ago, usually every 31"). This is not decoration. A voice agent reading a
-- bare ranked list has to invent a justification, and it will; giving it the
-- reason and the evidence as data is what stops it. Nothing in this table is a
-- score a rep cannot interrogate.
--
-- ═══ FIVE REASONS, IN PRECEDENCE ORDER ═════════════════════════════════════
--   1 reorder due      they buy it, they are at or past their own reorder point
--   2 stopped buying   they used to buy it and have missed roughly two cycles
--   3 on promotion     they already buy it and it is on promo right now
--   4 peers buy it     never bought, but accounts in the same NAV customer
--                      group do — needs var('account_item_peer_min_accounts')
--                      of them before the claim is worth making
--   5 new or featured  never bought, flagged new / popular by a buyer
--
-- The first three are MEASURED from this account's own posted purchases. The
-- last two are WEAKER and differently sourced, and the split matters: reasons
-- 4 and 5 rest on a buyer's manual flag or on other stores' behaviour, never on
-- anything this account did. is_evidence_based marks the difference so an
-- assistant can say "you are due for this" and "you might try this" in
-- different voices instead of reading all five in the same confident one.
--
-- ONE ROW PER ACCOUNT-ITEM. An item qualifying under several reasons keeps the
-- strongest and reason_count records how many it met — a candidate that is both
-- overdue AND on promotion is a better call than one that is merely overdue,
-- and collapsing that to one reason without saying so would lose it.
--
-- ═══ WHAT THIS LIST DOES NOT KNOW ══════════════════════════════════════════
-- STILL RANKED BY LIKELIHOOD, NOT VALUE, AND DELIBERATELY SO. Line amounts have
-- been exported since 2026-09-20, so avg_value_per_purchase can now say what a
-- typical reorder of this item is worth — but only for accounts whose recent
-- purchases fall inside that window, and null for everyone else. Ranking on a
-- column that is null for most rows would sort by "how recently did ADF see
-- this" rather than by opportunity, so the ranking stays on frequency and
-- recency, which cover the whole history.
--
-- Read the value as CONTEXT for a candidate the ranking already chose, not as
-- the reason it was chosen. A rep asking "which of these is worth most" can be
-- answered only where the value is populated, and the honest reply elsewhere is
-- that we cannot see it yet.
--
-- NO PRICE MEANS NO PROMOTION DEPTH EITHER. is_on_promotion says an item is on
-- a live promotion; it cannot say how good the offer is, and the promotion has
-- no name (see stg_nav__promotion_lines — which of promotion_line's two codes
-- joins to the header is unresolved).
--
-- ═══ STOCK GATES THE LIST, WITH ONE EXCEPTION ══════════════════════════════
-- An item the warehouse cannot ship is not an opportunity, so is_in_stock =
-- false is excluded outright. Items with NO WMS ROW are KEPT, because their
-- stock is unknown rather than zero — the mirror covers CABOT only and these
-- may ship from an unmirrored site. stock_is_known flags them so a rep is told
-- "I cannot see stock on this one" instead of being promised it.
--
-- Blocked items are excluded unconditionally: NAV blocking an item means it
-- cannot transact at all, and pitching it wastes a call.
--
-- ═══ THE CAP IS A CEILING, NOT A TARGET ════════════════════════════════════
-- An account with three good candidates gets three rows. Padding to ten with
-- weak suggestions is how a rep learns to ignore the list.

{% set top_n         = var('account_item_opportunity_top_n') %}
{% set peer_min      = var('account_item_peer_min_accounts') %}

with accounts as (

    select
        customer_key,
        customer_name,
        owner_rep,
        owner_rep_name,
        city,
        county,
        customer_group,
        delivery_days,
        delivery_day_count,
        appointment_required,
        is_active                                                        as customer_is_active
    from {{ ref('dim_customers') }}
    where not is_test_account

),

-- Sellable, and not known to be out of stock. Unknown stock survives; see the
-- header on why that is not the same as in stock.
sellable_items as (

    select
        item_no,
        item_label,
        item_category_code,
        item_category_name,
        abc_class,
        is_new_item,
        is_popular_item,
        is_on_promotion,
        promo_end_date,
        promo_price,
        promo_buy_qty,
        promo_free_qty,
        has_promo_offer,
        unit_price,
        is_discontinued,
        is_in_stock,
        has_wms_item,
        shippable_qty,
        stock_snapshot_date
    from {{ ref('dim_items') }}
    where is_sellable
      and coalesce(is_in_stock, true)   -- null (unmirrored item) is kept

),

history as (

    select * from {{ ref('mart_account_item_history') }}

),

-- ── reasons 1-3: this account's OWN measured purchase behaviour ───────────
own_behaviour as (

    select
        h.customer_key,
        h.item_no,
        case
            when h.reorder_status in ('due', 'overdue') then 'reorder due'
            when h.reorder_status = 'lapsed'            then 'stopped buying'
            when h.is_on_promotion                      then 'on promotion'
        end                                                              as opportunity_reason,
        h.times_purchased,
        h.last_purchase_date,
        h.days_since_last_purchase,
        h.median_days_between_purchases,
        h.expected_next_purchase_date,
        h.days_overdue,
        h.avg_quantity_per_purchase,
        h.primary_quantity_uom,
        h.avg_value_per_purchase,
        h.reorder_status,
        -- how many of the three this item met, so a candidate that is overdue
        -- AND on promotion outranks one that is only overdue.
        (case when h.reorder_status in ('due', 'overdue') then 1 else 0 end)
        + (case when h.reorder_status = 'lapsed'          then 1 else 0 end)
        + (case when h.is_on_promotion                    then 1 else 0 end)
                                                                         as reason_count
    from history as h
    where h.reorder_status in ('due', 'overdue', 'lapsed')
       or h.is_on_promotion

),

-- ── reason 4: what comparable accounts buy ────────────────────────────────
-- "Comparable" is NAV's own customer_group and nothing cleverer. It is a
-- grouping the business already maintains and can argue with, which beats a
-- similarity score nobody can audit. Accounts with a null customer_group get no
-- peer suggestions at all rather than being pooled into a meaningless "other".
peer_purchases as (

    select
        a.customer_group,
        h.item_no,
        count(distinct h.customer_key)                                   as peer_account_count
    from history as h
    join accounts as a on a.customer_key = h.customer_key
    where a.customer_group is not null
    group by a.customer_group, h.item_no

),

peer_candidates as (

    select
        a.customer_key,
        p.item_no,
        'peers buy it'                                                   as opportunity_reason,
        p.peer_account_count
    from accounts as a
    join peer_purchases as p on p.customer_group = a.customer_group
    where a.customer_group is not null
      -- the claim needs enough stores behind it to be worth saying out loud.
      -- Counted across the group INCLUDING this account, then excluded below —
      -- an account already buying the item is not a candidate for it.
      and p.peer_account_count >= {{ peer_min }}
      and not exists (
            select 1 from history as h
            where h.customer_key = a.customer_key
              and h.item_no      = p.item_no
      )

),

-- ── reason 5: the buyer's manual flags ────────────────────────────────────
-- The WEAKEST reason on the list, and the only one resting on nothing but
-- somebody having ticked a box. new_item's persistence is unconfirmed in the
-- source docs — an item flagged new may have been new two years ago — and
-- popular_item is explicitly "a MANUAL buyer flag, not a computed velocity
-- measure". Included because a rep genuinely does want to know what the buyers
-- are pushing; ranked last because it is not evidence.
featured_candidates as (

    select
        a.customer_key,
        i.item_no,
        'new or featured'                                                as opportunity_reason
    from accounts as a
    cross join sellable_items as i
    where (i.is_new_item or i.is_popular_item)
      and not exists (
            select 1 from history as h
            where h.customer_key = a.customer_key
              and h.item_no      = i.item_no
      )

),

-- ── one candidate list ────────────────────────────────────────────────────
candidates as (

    select
        customer_key,
        item_no,
        opportunity_reason,
        reason_count,
        times_purchased,
        last_purchase_date,
        days_since_last_purchase,
        median_days_between_purchases,
        expected_next_purchase_date,
        days_overdue,
        avg_quantity_per_purchase,
        primary_quantity_uom,
        avg_value_per_purchase,
        cast(null as {{ dbt.type_int() }})                               as peer_account_count,
        true                                                             as is_evidence_based
    from own_behaviour
    where opportunity_reason is not null

    union all

    select
        customer_key,
        item_no,
        opportunity_reason,
        1                                                                as reason_count,
        cast(null as {{ dbt.type_int() }})                               as times_purchased,
        cast(null as date)                                               as last_purchase_date,
        cast(null as {{ dbt.type_int() }})                               as days_since_last_purchase,
        cast(null as {{ dbt.type_numeric() }})                           as median_days_between_purchases,
        cast(null as date)                                               as expected_next_purchase_date,
        cast(null as {{ dbt.type_numeric() }})                           as days_overdue,
        cast(null as {{ dbt.type_numeric() }})                           as avg_quantity_per_purchase,
        cast(null as {{ dbt.type_string() }})                            as primary_quantity_uom,
        cast(null as {{ dbt.type_numeric() }})                           as avg_value_per_purchase,
        peer_account_count,
        false                                                            as is_evidence_based
    from peer_candidates

    union all

    select
        customer_key,
        item_no,
        opportunity_reason,
        1                                                                as reason_count,
        cast(null as {{ dbt.type_int() }})                               as times_purchased,
        cast(null as date)                                               as last_purchase_date,
        cast(null as {{ dbt.type_int() }})                               as days_since_last_purchase,
        cast(null as {{ dbt.type_numeric() }})                           as median_days_between_purchases,
        cast(null as date)                                               as expected_next_purchase_date,
        cast(null as {{ dbt.type_numeric() }})                           as days_overdue,
        cast(null as {{ dbt.type_numeric() }})                           as avg_quantity_per_purchase,
        cast(null as {{ dbt.type_string() }})                            as primary_quantity_uom,
        cast(null as {{ dbt.type_numeric() }})                           as avg_value_per_purchase,
        cast(null as {{ dbt.type_int() }})                               as peer_account_count,
        false                                                            as is_evidence_based
    from featured_candidates

),

-- Stock and sellability gate the whole list, applied ONCE here rather than in
-- each branch above, so a rule change cannot be applied to four of five
-- reasons.
gated as (

    select
        c.*,
        i.item_label,
        i.item_category_code,
        i.item_category_name,
        i.abc_class,
        i.is_new_item,
        i.is_popular_item,
        i.is_on_promotion,
        i.promo_end_date,
        i.promo_price,
        i.promo_buy_qty,
        i.promo_free_qty,
        i.has_promo_offer,
        i.unit_price,
        i.is_discontinued,
        i.is_in_stock,
        i.has_wms_item,
        i.shippable_qty,
        i.stock_snapshot_date,
        case
            when c.opportunity_reason = 'reorder due'     then 1
            when c.opportunity_reason = 'stopped buying'  then 2
            when c.opportunity_reason = 'on promotion'    then 3
            when c.opportunity_reason = 'peers buy it'    then 4
            when c.opportunity_reason = 'new or featured' then 5
        end                                                              as reason_rank
    from candidates as c
    join sellable_items as i on i.item_no = c.item_no

),

-- One row per account-item: the strongest reason wins, and reason_count
-- records that others were met.
deduped as (

    select
        g.*,
        row_number() over (
            partition by g.customer_key, g.item_no
            order by g.reason_rank, g.reason_count desc
        )                                                                as _item_rn
    from gated as g

),

ranked as (

    select
        d.*,
        row_number() over (
            partition by d.customer_key
            order by
                d.reason_rank,
                -- within a reason: more corroborating reasons first, then the
                -- most overdue, then the most frequently bought. Every tiebreak
                -- is a measured quantity, so the order is reproducible and a
                -- rep can be told why one item came before another.
                d.reason_count            desc,
                d.days_overdue            desc nulls last,
                d.times_purchased         desc nulls last,
                d.peer_account_count      desc nulls last,
                d.item_no
        )                                                                as opportunity_rank
    from deduped as d
    where d._item_rn = 1

)

select
    -- ── who ───────────────────────────────────────────────────────────────
    r.customer_key,
    a.customer_name,
    a.owner_rep,
    a.owner_rep_name,
    a.customer_is_active,
    a.city,
    a.county,
    a.customer_group,

    -- ── what to pitch ─────────────────────────────────────────────────────
    r.item_no,
    r.item_label,
    r.item_category_code,
    r.item_category_name,
    r.abc_class,

    -- ── the ranking. 1 = lead with this ───────────────────────────────────
    r.opportunity_rank,
    r.opportunity_reason,
    r.reason_count,
    -- TRUE = this account's own posted purchases justify the suggestion.
    -- FALSE = it rests on other accounts' behaviour or on a buyer's manual
    -- flag. Say these two differently.
    r.is_evidence_based,

    -- ── the evidence, already phrased for a person ────────────────────────
    -- Assembled here rather than left to the consumer so that every reading of
    -- this row makes the same claim. Note what it never contains: a value, a
    -- price, or a margin — none exist in the source.
    case
        when r.opportunity_reason = 'reorder due' then
            concat('bought ', cast(r.times_purchased as {{ dbt.type_string() }}),
                   ' times, last ', cast(r.days_since_last_purchase as {{ dbt.type_string() }}),
                   ' days ago, usually every ',
                   cast(cast(round(r.median_days_between_purchases, 0) as int) as {{ dbt.type_string() }}),
                   ' days')
        when r.opportunity_reason = 'stopped buying' then
            concat('bought ', cast(r.times_purchased as {{ dbt.type_string() }}),
                   ' times but nothing for ',
                   cast(r.days_since_last_purchase as {{ dbt.type_string() }}),
                   ' days, against a usual ',
                   cast(cast(round(r.median_days_between_purchases, 0) as int) as {{ dbt.type_string() }}),
                   '-day cycle')
        -- THE OFFER, NOT THE PRICE. NAV sets no price on any promotion live
        -- today (0 of 86, measured 2026-09-23), so quoting one would be quoting
        -- a null. The buy-X-get-Y mechanic is what is maintained, so it leads
        -- where present and the bare window is the fallback.
        when r.opportunity_reason = 'on promotion' and r.has_promo_offer then
            concat('already buys this — buy ',
                   cast(cast(r.promo_buy_qty as int) as {{ dbt.type_string() }}),
                   ' get ',
                   cast(cast(r.promo_free_qty as int) as {{ dbt.type_string() }}),
                   ' free until ',
                   cast(r.promo_end_date as {{ dbt.type_string() }}))
        when r.opportunity_reason = 'on promotion' then
            concat('already buys this and it is on promotion until ',
                   cast(r.promo_end_date as {{ dbt.type_string() }}))
        when r.opportunity_reason = 'peers buy it' then
            concat(cast(r.peer_account_count as {{ dbt.type_string() }}),
                   ' other accounts in group ', coalesce(a.customer_group, '?'),
                   ' buy this; this one never has')
        when r.opportunity_reason = 'new or featured' then
            case when r.is_new_item then 'flagged as a new item and never bought here'
                 else 'flagged popular by the buyers and never bought here' end
    end                                                                  as opportunity_evidence,

    -- ── the measured facts behind reasons 1-3. Null for 4 and 5 ───────────
    r.times_purchased,
    r.last_purchase_date,
    r.days_since_last_purchase,
    r.median_days_between_purchases,
    r.expected_next_purchase_date,
    r.days_overdue,
    -- what a reorder would typically look like, in the account's own UOM.
    -- QUANTITY ONLY — there is no price to turn it into a value.
    r.avg_quantity_per_purchase,
    r.primary_quantity_uom,
    -- what a typical reorder of this item is WORTH to this account. NULL where
    -- their recent purchases predate the 2026-09-20 value export, and for the
    -- two reasons that rest on no purchase history at all. Context for the
    -- candidate, never the basis of the ranking — see the header.
    r.avg_value_per_purchase,
    r.peer_account_count,

    -- ── can we ship it ────────────────────────────────────────────────────
    -- stock_is_known false means the WMS mirror does not cover this item at
    -- all; it survived the stock gate because unknown is not zero. Tell the rep
    -- that rather than promising availability.
    r.has_wms_item                                                       as stock_is_known,
    r.is_in_stock,
    r.shippable_qty,
    r.stock_snapshot_date,

    -- ── merchandising context ─────────────────────────────────────────────
    r.is_on_promotion,
    r.promo_end_date,
    -- The OFFER. promo_price is null on virtually every live promotion because
    -- NAV does not set one — never render that as free. has_promo_offer says
    -- whether the buy/free pair is worth reading out.
    r.has_promo_offer,
    r.promo_buy_qty,
    r.promo_free_qty,
    r.promo_price,
    -- LIST price, so a never-bought candidate can still be priced. What the
    -- account itself paid is avg_value_per_purchase, and that is the better
    -- number wherever it exists.
    r.unit_price,
    r.is_new_item,
    r.is_popular_item,
    -- Being phased out. Not excluded — a discontinued item can still be sold
    -- and sometimes wants clearing — but a rep should know before pitching it.
    r.is_discontinued,

    -- ── when the call has to happen ───────────────────────────────────────
    a.delivery_days,
    a.delivery_day_count,
    a.appointment_required
from ranked as r
join accounts as a on a.customer_key = r.customer_key
where r.opportunity_rank <= {{ top_n }}
