{% docs social_time_windows %}

## The five time windows in the social trending feature

Five different periods govern this feature, and they are independent. Confusing two
of them is the easiest way to misread the board or to spend money for nothing, so
they are all defined here once and referenced from everywhere else.

| # | Window | Length | Set in | Governs |
|---|---|---|---|---|
| 1 | **Ranking** | **1 calendar week** | fixed (the grain) | every published number: `trend_rank`, `trend_score`, `mention_count`, `mention_share` |
| 2 | **Comparison** | the **immediately preceding** week | fixed | `rank_change`, `is_rising`, `mention_share_change`, `mention_count_wow_pct` |
| 3 | **Retention** | 13 weeks (~3 months), rolling | `social_trend_history_weeks` | how many weeks the table keeps — chart length only |
| 4 | **Re-label** | 4 weeks | `social_enrich_backfill_weeks` | how far back a `PROMPT_VERSION` bump re-labels mentions |
| 5 | **Snippet evidence** | 28 days | `SNIPPET_WINDOW_DAYS` in `resolve_trending_concepts.py` | how much mention text the SKU resolver reads to decide what a token *means* |

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

{% enddocs %}
