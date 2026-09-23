# UST Sales Agent — Unity Catalog tables, coverage, and what they answer

Status as of **2026-09-23**. Maps *Draft UST Sales Agent Questions* (9/8/2026) onto
the tables that answer it, what is still outstanding, and the queries each table
supports.

Everything lives in the `ust_databricks` catalog. Read this before pointing the
agent at anything: several tables carry a deliberate caveat that changes what a
correct answer sounds like.

---

## 1. The five things to know before quoting any number

These recur throughout and each one has caused, or nearly caused, a wrong answer.

**Dollars only reach back to 2026-09-20.** ADF began exporting line amounts on that
date. The blob's historical seed still carries the old column list and the daily
exports are deltas, so history is *never* revisited: 19,654,620 of 19,696,349
invoice lines have no amount and always will, unless the seed is re-exported.
Counts, dates and quantities are complete throughout — only money is recent. Every
table that carries value also carries a coverage column (`has_value`,
`value_coverage`, `valued_purchase_days`, `return_rate_is_measurable`). **Read the
coverage column before quoting the value.**

**Nothing is coalesced to zero.** A line with no exported amount has no value. A
zero would average into every revenue figure as though the goods were given away,
so these are NULL and stay NULL.

**There are three clocks and they are different dates.**

| clock | source | used by |
|---|---|---|
| `rep_log_today()` | mysql event log | app-order columns, rep activity |
| `nav_posted_today()` | NAV posted invoices | purchases, invoices, receivables |
| `stock_snapshot_date` | WMS `inv_snap` (last night) | in-stock |

They advance on independent schedules. Any table carrying more than one publishes
both; an answer should say which it used.

**Orders and invoices will never tie out.** `fct_orders` is what a rep *submitted*
(app channels, same-day). `fct_invoices` is what was *invoiced* (every channel,
full history, lags posting). Orders get cut, short-shipped or posted days later.
Say which you mean.

**A customer name is not a key.** 222 of 3,742 active customers share a name with
another account. `ASIAN MARKET` is **22 different accounts**; `LEE'S SANDWICHES` in
`SAN JOSE` is still 3. Normalising case and punctuation makes this *worse*, not
better — colliding groups go from 85 to 92 — so resolving a spoken name is a
disambiguation problem, not a matching one. Every mart carries `city`, `county`,
`post_code` and `owner_rep_name` beside the name for that purpose. An agent that
takes the first match on a name will eventually bill the wrong store.

Rep names have no such problem: ~15 codes, all distinct.

**Absent does not mean zero.** `has_store_type` false means unknown, not "none of
the above" (half the active book). `is_in_stock` null means the WMS mirror does not
cover the item, not out of stock. `return_rate_is_measurable` false means we cannot
see it, not that returns are fine.

---

## 2. Tables, by PDF section

### How am I doing?

| UC table | status |
|---|---|
| `ust_reporting.mart_rep_period_status` | ✅ built — target attainment TBD |
| `ust_reporting.mart_rep_period_item_mix` | ✅ built — branded % TBD |
| `ust_facts.fct_invoices` | ✅ built |
| `ust_reporting.mart_account_period_status` | ✅ built |
| `ust_facts.fct_orders` | ✅ existing |

**Answers**

- "How am I doing this month / this quarter / yesterday?" — orders, value, distinct
  accounts, average order value, biggest order and who it was from
- "3 PDA orders, 2 app orders, 1 web order — PDA orders were $123, app were $111"
- "How does that compare to last month?" — strictly the preceding period, never a
  gap-skipping `lag`
- "Where will I land by month end at this pace?" — straight-line projection on
  complete data, not against the wall clock
- "What did I actually sell last month, net of returns?" — from posted invoices,
  which is what the PDF asks for over the event log
- "How did ABC do last month, and what came back?" — `mart_account_period_status`,
  with the 2–3% alert as `returns_over_threshold`
- "What was my month made of?" — category, promo, new-item shares, by line **and**
  by value

**Not answerable:** "will I hit my target" (needs `Salesperson Target`), "branded
sales is 40%" (needs `Sales Person Margin History` **and** a brand definition),
average AR days, bounce-check warning, credit warning.

### Am I going to make my number?

| UC table | status |
|---|---|
| `ust_reporting.mart_rep_period_status` | ⏳ pace built, **targets TBD** |

Everything in this section — 68% of baseline, "you still need $25k", ahead or
behind for this point in the month, same month last year — waits on
`navrep.salesperson_target`. The pace projection and period comparisons already
work; only the goal to compare against is missing.

"Focus items" is degraded rather than blocked: the flag exists on `dim_items`, but
only 5 items carry it and four have a window from **July 2017**. NAV is not
maintaining it.

### What should I sell them?

| UC table | status |
|---|---|
| `ust_reporting.mart_account_item_history` | ✅ built |
| `ust_reporting.mart_account_item_opportunities` | ✅ built |
| `ust_dims.dim_items` | ✅ built |
| `ust_intermediate.int_customer_item_cadence` | ✅ built |
| `ust_intermediate.int_customer_item_purchases` | ✅ built |

**Answers**

- "What does this account actually buy, item by item?"
- "What have they stopped buying, and when did they last buy it?" — `lapsed` fires
  at twice *that account's own* median gap, so a quarterly buyer must miss roughly
  two quarters, not two months
- "What are they due to reorder?" — on the account's own rhythm, derived per
  account-item from its own purchase gaps rather than a company-wide threshold.
  This is also the answer to the PDF's "quarterly vs. monthly customer" note
- "What 5–10 items should I walk in and talk about?" — ranked, each row carrying
  its own reason *and* the evidence for it
- "Is it in stock before I recommend it?" — CABOT only, as of last night
- "Buy 6 get 1 free until the 30th" — the promo mechanic

**Caveat that shapes answers:** the pitch list separates `is_evidence_based` (the
account's own purchases) from the two weaker reasons (peers buy it, new or
featured). Say those differently — "you are due for this" versus "you might try
this".

### Who should I call?

| UC table | status |
|---|---|
| `ust_reporting.mart_rep_account_status` | ✅ built — AR columns TBD |
| `ust_reporting.mart_rep_nearby_accounts` | ✅ built |
| `ust_dims.dim_customers` | ✅ built |

**Answers**

- "Who should I call today?" — every account owned in NAV *or* sold to in fact
- "Who's gone quiet?" — now on **posted invoices**, so an account that buys by
  phone or email no longer reads "no order on record"
- "I'm at ABC Market — who else round here has gone quiet?" — within 5 km,
  straight-line, ranked by urgency then distance
- "Which days does this store take deliveries?" — so a call lands before the cut-off

**Not answerable:** "which accounts are past their terms" (needs
`Customer Outstanding Balance`).

---

## 3. Asking by name

Every code column in every consumer-facing table now sits beside its name, so no
join is needed to *display* one — `customer_name`, `rep_name`, `owner_rep_name`,
`selling_rep_name`, `item_label`.

Going the other way — a spoken name to an account — needs care, because names
repeat (see §1). The pattern that works:

1. Look the name up in `ust_dims.dim_customers`, returning `customer_key`,
   `customer_name`, `city`, `post_code` and `owner_rep_name`
2. **One match** — proceed
3. **Several** — ask. "There are three accounts called Lee's Sandwiches in San
   Jose — is it the one on Story Road?" Address and owner rep are the tiebreakers
4. **None** — say so rather than guessing at the nearest string

`owner_rep` is usually the strongest filter in practice: a rep asking about "Asian
Market" almost always means one of *theirs*, which narrows 22 accounts to one or
two. Scoping the lookup to the calling rep's book before anything else is the
cheapest disambiguation available.

`selling_rep_name` and `owner_rep_name` are different people whenever a rep sells
into a colleague's account, so an answer naming a rep should say which it means.

---

## 4. Supporting tables

| UC table | role |
|---|---|
| `ust_dims.dim_customers` | account, owner rep, delivery days, store type, coordinates |
| `ust_dims.dim_items` | item name, category, price, stock, promo / new / focus, lifecycle |
| `ust_dims.dim_reps` | rep territory code and name |
| `ust_staging.stg_nav__sales_invoice_lines` | posted sales lines — value, UOM conversion |
| `ust_staging.stg_nav__sales_cr_memo_lines` | posted credit lines |
| `ust_staging.stg_nav__sales_invoice_headers` | invoice dates, due date, channel keys |
| `ust_staging.stg_nav__items` | NAV item master |
| `ust_staging.stg_nav__customers` | NAV customer master |
| `ust_staging.stg_nav__promotion_lines` | promotion items and offers |

---

## 5. TBD

### Waiting on ADF — four NAV tables not yet in `navrep`

| NAV table | unlocks |
|---|---|
| `Salesperson Target` | the entire "Am I going to make my number?" section |
| `Customer Outstanding Balance` | `fct_open_receivables`, past-terms, AR days |
| `Sales Person Margin History` | branded % of sales |
| `Salesperson_Purchaser` | the AR / brand / margin targets to judge against |

Two tables remain unbuilt pending these: **`fct_open_receivables`** and a
rep-level **`mart_rep_ar_status`** (so the agent is not computing a weighted
average across hundreds of open invoices on the fly).

### Waiting on ADF — two columns

`Item.Marked New Date` and `Item.Removed New Date`. The exported
`New Begin Date` / `New End date` are blank on the items that matter — all 357
flagged items have a blank end date, so nothing can ever show as *currently* new.
`Marked New Date` is set on all 357 and `Removed New Date` on none, which is
exactly "currently new". Until then `dim_items.is_new_now` is false for every item
by design.

### Waiting on a person

**What defines "Brand" vs "Other"?** There is no brand field on the NAV item record
and no brand master, but `Brand Sales Amount` and `Target Brand %` both exist — so
the rule is hardcoded somewhere. Without it, branded % can be *calculated* once
`Sales Person Margin History` lands, but not *explained*.

**Are the focus-item windows maintained?** NAV holds a July 2017 campaign. The PDF
already says "confirm with Vince again" — this is that confirmation.

**What is the payment-terms mapping?** Needed to age open receivables across full
history, since invoice `Due Date` is only populated from 2026-09-20.

### No source anywhere

| PDF item | why |
|---|---|
| "Individual store target" | `Customer.Budgeted Amount` is **zero on all 7,242 customers in NAV itself** — verified against source. Not an ingestion fault; the field is not maintained |
| "Bounce check warning" | Nothing in NAV's catalog covers bounced or NSF payments |
| "Credit warning" | `Credit Limit (LCY)` was scoped out of the ADF request |
| "Check invoice and GL" | Too vague to source |

### Decision outstanding

The pitch list is ~94% `new or featured` rows, because an account with no purchase
history receives ten flagged items. The ranking works as designed — evidence-based
reasons rank first — but whether a never-bought account should get a full list, a
shorter one, or none, is a business call.

---

## 6. Coverage summary

Roughly **25 of ~30 PDF bullets** are answerable today. Of the rest:

- 5 wait on the four NAV tables
- 1 waits on two item columns
- 4 have no source at all

The unit history — what accounts buy, how often, what they have stopped buying,
when they are due — is **complete across the whole ERP export**. Only the money is
recent, and it fills forward from 2026-09-20 as the daily exports accumulate.
