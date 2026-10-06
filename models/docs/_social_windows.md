{% docs social_time_windows %}

## The time windows in the social trending feature

Several different periods govern this feature, and they are independent. Confusing two
of them is the easiest way to misread the board or to spend money for nothing, so
they are all defined here once and referenced from everywhere else.

**Since 2026-10 the board a reader sees is `int_social_trend_board`, not the weekly
ranking.** The weekly ranking (windows 1-2) is still computed and still published per
week, but the board — who is on it, in what order, with what status — is the faded,
sticky board of windows 6-9 below, over PRODUCTS rather than spellings (see "One
product, one name" at the end).

| # | Window | Length | Set in | Governs |
|---|---|---|---|---|
| 1 | **Ranking** | **1 calendar week** | fixed (the grain) | the WEEKLY numbers: `trend_rank`, `trend_score`, `mention_count`, `mention_share` |
| 2 | **Comparison** | the **immediately preceding** week | fixed | `rank_change`, `is_rising`, `mention_share_change`, `mention_count_wow_pct` |
| 3 | **Retention** | 13 weeks (~3 months), rolling | `social_trend_history_weeks` | how many weeks the table keeps — chart length only |
| 4 | **Re-label** | 4 weeks | `social_enrich_backfill_weeks` | how far back a `PROMPT_VERSION` bump re-labels mentions |
| 5 | **Snippet evidence** | 28 days | `SNIPPET_WINDOW_DAYS` in `resolve_trending_concepts.py` | how much mention text the SKU resolver reads to decide what a token *means* |
| 6 | **Fade** | half-life 2 weeks (~3-4 week tail) | `social_trend_fade_half_life_weeks` | `faded_score`, `board_rank`: a week's share counts 100%, ~71%, 50%, ~35%, 25% after it |
| 7 | **Stay-on** | entered within 3 weeks, top 25, posted within 4 normal weeks | `social_trend_stay_window_weeks`, `_stay_rank`, `_quiet_weeks_to_drop` | who stays on the board after the fast lane or the top 20 let them on |
| 8 | **Coverage** | per week, vs the retained weeks' median | `social_trend_low_coverage_ratio` | `is_low_coverage`: a data hole stops the fade clock instead of reading as quiet |
| 9 | **Rising** | last 4 normal weeks vs the 8 before | `social_trend_rising_*` | `is_rising_candidate`, `rising_rank`, `rising_growth` |

### 1. Ranking — one calendar week, and only complete ones

Monday-anchored (`posted_week`). A week's row is built from that week's mentions
alone and ranked against only that week's other concepts, so week-to-week movement
compares equal, non-overlapping periods.

An **incomplete week is not computed at all**. The weekly export lands mid-week, so
the calendar week in progress is usually a fragment, and a fragment cannot be ranked
against a whole week — its counts are down by half for a reason that has nothing to
do with any trend. It appears on the next run, once it is whole. Consequences:
`max(week_start)` is always a finished week and needs no qualification, and the first
week ever collected is dropped permanently since it can never become complete.

**Accepted cost:** a calendar boundary splits a trend. A spike running Saturday to
Tuesday lands half in each of two weeks and ranks lower in both. An earlier design
used a trailing multi-week window to avoid exactly this, at the price of overlapping
periods that cannot be compared week to week; this grain takes the other side of that
trade deliberately.

### 2. Comparison — strictly last week, or nothing

`lag()` walks a concept's *observed* weeks, and a week under
`social_trend_min_mentions` produces no row. Ungated, a concept that charted in W29,
went quiet in W30 and returned in W31 would report "+6 places" against W29 —
indistinguishable, in the number itself, from a real one-week move. So all four
movement measures are populated **only** when the previous row is exactly the
previous calendar week.

NULL therefore means *no like-for-like comparison exists* — first appearance, a
skipped week, or a week either side excluded as `repeat_poster`. It does **not** mean
"flat". Never `coalesce` these to 0 in a dashboard. `prev_week_start` carries the
older week, so a longer-range comparison is available on request; it just is not
served up as if it were weekly.

### 3. Retention — chart length, nothing else

Verified by building at 13 weeks and at 4 and diffing the latest week: 27 rows
identical including `trend_score` to 10 decimal places. Retention is used in exactly
one place (which weeks enter the model) and **cannot change any rank**. Shortening it
shortens the chart and nothing else; lengthening it costs almost nothing.

The one cross-week term in the score is the thin-channel median fallback, and that
reads all history *before* retention applies, so it does not move either.

Rolling and unarchived: the model is a full rebuild, so when week 14 arrives week 1
is gone. Seasonality questions ("was durian bigger than last year") need a snapshot
table, and history has to be retained from now to be there later.

### 4. Re-label — the cost control on prompt changes

Every number for a week comes from that week's mentions alone, so labels only need to
be current for the weeks still being ranked and compared. Older mentions keep the
labels they have: they stay in `fct_social_mentions`, keep feeding the dish class and
the all-history channel medians, and simply lack whatever field a newer prompt added.

So a `PROMPT_VERSION` bump re-labels ~4 weeks rather than the whole corpus. Outside
the window a mention counts as done if it is enriched at all.

**Week-aligned, and that is the part that matters.** A *partially* re-labelled week is
the one genuinely broken state: `mention_share`'s denominator is that week's labelled
pairs, so if only a handful of a week's mentions carry a new array, those few become
the entire universe for that week and read ~1.0 with meaningless ranks. A wholly
un-relabelled week is harmless by comparison — it just has no rows for the new field.
This is why the setting is in weeks, and why `--limit` is a smoke-test flag only.

**Known cost:** a bump leaves a label-version boundary inside the retention window, so
one week-over-week comparison partly reflects the prompt change rather than real
movement. Ranks either side stay valid, each week being internally consistent.

### 5. Snippet evidence — deliberately NOT the ranking week

The resolver shows the model real mention text so it can tell what a token means — a
bare "pork" is หมูกระจก or หมูกระทะ, never "pork skin". That job needs enough text to
be conclusive, which one calendar week may not provide: a mid-week run can leave the
latest week with a day or two of posts, few enough to leave a concept with no usable
snippets, which is precisely how a bare token gets guessed at.

So the snippet window is 28 days ending at the ranked week — recent enough that the
token has not drifted, wide enough to explain it. It is read from
`fct_social_mentions` (all history available), not from the trends table, so it is
unaffected by retention.

Related but not a window: the resolver's **gate** gives it only the current week's
top-N of each class. Historical weeks reuse those resolution rows, because a
concept→SKU mapping is timeless.


### 6. Fade — why the board stopped forgetting

Ranked one week at a time, a viral product was gone the week its posting slowed:
measured 2026-10-05 on the real corpus, 63% of the item board changed every week and an
item stayed 1.6 weeks on average. Sponge cake — 32 posts the week of Aug 24, then 15,
3, 0, 3 — was on the board for exactly one week.

`faded_score` = sum over past weeks of the product's weekly signal x 0.5^(normal weeks
since / half-life). The SIGNAL is the product's share of its board's trend_score that
week, not the score: the feed changed size three times in 2026 for reasons that are not
trends (the keyword cut of Aug 16-17 halved the Thai tracker's keywords; the monthly
quota ran out ~Sep 8-21; enrichment v3 -> v4 found ~15-20% more products per post), and
shares make those weeks comparable. At the shipped settings churn fell to ~17% and an
item stays ~4.5 weeks once on.

**Known limit:** shares neutralise how MUCH the feed collected, not WHAT it collected.
The Aug 17 keyword cut removed broad "viral / must try / review / 7-Eleven new" searches,
so cooking-related products became a bigger share of what remained — that reads as
growth on the Rising list (window 9) until its baseline is entirely post-change, about
eight normal weeks later. A keyword change is therefore a feed event worth writing down
with its date.

### 7. Stay-on — easy to get on, harder to fall off

On the board = top `social_trend_top_n` by faded score, OR top `social_trend_top_n` by
THIS week's weekly rank (the fast lane — a new spike is on in its first week, before its
faded score has built up), OR it got on within `social_trend_stay_window_weeks`, is still
in the top `social_trend_stay_rank` by faded score, and has had posts within
`social_trend_quiet_weeks_to_drop` normal weeks. A week excluded as a `repeat_poster` is
never on the board. A looser rule (top 40, 4-week window) froze the board at 9% churn
with ~40 entries — sticky enough to stop showing anything new.

`board_status`: **new** (first week of a run on the board), **rising** (this week's share
>= 1.25x last week's), **cooling** (a quiet week, or share under half the run's peak),
**steady** otherwise — and steady in a low-coverage week, because a hole in the data
says nothing about the product. `weeks_on_board` and `best_board_rank` describe the
current run.

### 8. Coverage — a hole is not a quiet week

A week whose food-post count is below `social_trend_low_coverage_ratio` (0.4) x the
retained weeks' median is flagged `is_low_coverage`. In it the fade clock stops (nothing
decays, nothing counts as quiet) and the fast lane is closed (a handful of posts is not
a spike), but its posts still add to the score. 2026's flagged weeks: the June-July
collection ramp-up, and Sep 7 / Sep 14, when the monthly Mentionlytics quota ran out
(~650 posts a day fell to 13-50 from Sep 8 until it reset around Sep 22).

### 9. Rising — picking up against its own history

The product's average share over the last `social_trend_rising_recent_weeks` (4) normal
weeks vs the `social_trend_rising_baseline_weeks` (8) before them; at least
`social_trend_rising_min_growth` (2x), with floors on posts and distinct authors in the
recent window, and at least `social_trend_rising_min_baseline_weeks` normal weeks of
baseline. A staple talked about every week sits near 1x and never qualifies; a product
new to the feed (no baseline share at all) qualifies on volume alone. This is the
"potential trend" list — read it beside the board, not instead of it.

### One product, one name (not a window, but it changes every number above)

Every dish / product NAME the enrichment ever extracted — all history, not the 13
retained weeks — is mapped once by `scripts/canonicalize_concepts.py` to a canonical
product, and `int_social_concept_canon` gives each product one key, one display name and
one board (item vs dish, by its spellings' posts). `int_social_concept_trends` applies the
map BEFORE counting, so a post naming two spellings counts once
(`assert_social_merged_product_counts_each_post_once`). Measured 2026-10-05: Lay's ice
cream had been split across 9+ names on both boards, and the July salted-egg sponge cake
spike sat on the dish board at #204. The map covers all history because promo matching
reads all history too. Three LLM steps, in this order, each followed by a dbt rebuild of
`int_social_concept_canon`:
1. **names -> products** (`canonicalize_concepts.py`), each name once;
2. **consolidate** (`--consolidate`): products whose names share most of their words are
   asked "same product?" in small star-shaped groups. Never merges a branded product
   with an unbranded one (the first run tried "fresh eggs" -> "cp fresh eggs"). Same words
   in a different order need no LLM: `int_social_concept_canon` merges those itself;
3. **label products** (`--profile-products`): branded / shelf / generic + brand, for ALL
   products. `int_social_trend_board` ranks branded + shelf products as their own scope,
   ahead of every generic category (`assert_social_board_shelf_before_generic`).

Then dbt builds the trends and the board, the resolver runs, and dbt builds the mart.

**Labels a person can correct.** `int_social_product_labels` applies
`seed_social_product_overrides` over the LLM's label (a blank field keeps the LLM's
value) and gives every brand ONE spelling (`brand_key` folds "Lay's" / "Lays"). After a
label run, review the products near the top of the board and add a seed row for anything
wrong — cheaper and more certain than re-labelling 22k products.

**"Which Pepsi? which Magnum?"** `int_social_product_variants` lists, for every board
product each week, its related products with their posts over the last
`social_trend_variant_window_weeks` (`top_variants` on the mart): the same brand for a
branded product, or a longer name containing its whole name otherwise. Deterministic —
an LLM "family / variant" label was tried and grouped one family several ways depending
on batch order. It is an evidence list, not a hierarchy: every product still ranks on its
own, and promo matching still works at flavour level. The window is RECENT on purpose:
Pepsi's Dubai-chocolate posts ran late July - Aug 24, so the Sep 21 row shows the brand
campaign that week, not July's flavour.

**SKU matching follows the board.** `resolve_trending_concepts.py` resolves the weekly
top-N PLUS every product on the board, so a product held on through a quiet week still
gets its "do we carry it" answer.

{% enddocs %}
