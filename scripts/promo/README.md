# Monthly promo × social match: runbook

Each month UST's promo items are matched against social listening (Mentionlytics) and
searched on YouTube, TikTok and RedNote. The result is one workbook,
`UST_<MON>_Promo_Social_Listening_Match.xlsx`, with one row per promo item and its best
posts per language.

This page is **how to run it**. How the matching decides Exact / Close, the brand codes and
the known false positives are in [models/docs/_promo_social.md](../../models/docs/_promo_social.md).

## The monthly run, step by step

| # | Step | Where |
|---|---|---|
| 1 | Merge the month's files into one INPUT workbook | Claude |
| 2 | Validate it | your machine |
| 3 | Upload it and run the job | Databricks (unattended) |
| 4 | Download the output workbook | Databricks |
| 5 | TikTok search (English, Thai, Vietnamese) | Claude in Chrome, by hand |
| 6 | RedNote search (Chinese) | Claude in Chrome, by hand |

### 1. Merge the files

UST sends the promo list (e.g. `UST 2026 NOV NEW PROMO.xlsx`) and, since November 2026, a
description file with photos (e.g. `UST 2026 NOV NEW - desc.xlsx`). Their layouts change
from month to month, so they are merged into one workbook in a fixed layout.

Attach all of the month's files to Claude and paste
[prompts/promo_merge_input.md](prompts/promo_merge_input.md). You get back
`UST <YYYY> <MON> PROMO INPUT.xlsx`:

- **`items`**: one row per promo-list row, in fixed columns: `promo_month`,
  `promo_list` (NEW/PROMO), `item_no`, `description`, `size`, the optional promo columns,
  and the description file's `brand`, `short_description`, `selling_points`, `notes` and
  `photo`.
- **`meta`**: schema version, month, merge date, and the source files used.
- **`unmatched_detail`** (only when needed): description-file items that are on no promo
  list. They are not loaded; ask whether they were meant to be on promotion.

The promo list is the master list. The description file only adds detail to items on
it, joined by item number. The full column list is
[promo_input_schema.py](promo_input_schema.py).

### 2. Validate

```
python scripts/promo/validate_promo_input.py "C:/Users/<you>/Downloads/UST 2026 NOV PROMO INPUT.xlsx"
```

- **ERROR** lines must be fixed (ask Claude to correct the file, or fix the cell): a
  blank required column, an item number that isn't digits, a date not in `YYYY-MM-DD`,
  the same item twice on one list, a month that doesn't match the file name.
- **warning** lines are for reading: coverage (how many items have a description or
  photo), unmatched description rows, optional columns no source had.
- It ends with `valid, ready to load` or `NOT ready to load`.

The job runs the same check and refuses a file with errors.

### 3. Upload and run

1. Upload **only the INPUT workbook** to `/Volumes/ust_databricks/social/promo_landing/`.
2. Open the job **ust-promo-social-match** and click **Run now**. Nothing starts on upload.

The job ([scripts/databricks/promo_social_job.yml](../databricks/promo_social_job.yml))
runs, in order:

| Task | Script | What it does |
|---|---|---|
| load | [load_promo_list.py](load_promo_list.py) | validates and loads the items; saves photos to `promo_landing/_photos/<YYYYMM>/` |
| dbt | | builds the items |
| draft terms | [draft_promo_terms.py](draft_promo_terms.py) | AI drafts brand, product, flavor and search phrases for items not in the reviewed seed |
| dbt | | |
| match social | [match_promo_social.py](match_promo_social.py) | keyword pass over every Mentionlytics post, then the AI judge |
| dbt | | |
| YouTube | [youtube_search.py](youtube_search.py) | searches English, Thai and Vietnamese phrases (never Chinese), judges each video |
| dbt + tests | | the mart and every promo test; a failing test stops the export |
| export | [export_promo_social_match.py](export_promo_social_match.py) | writes the workbook |

A rerun of the same month is cheap: YouTube results are cached per item and month, and
judged posts are not judged again.

### 4. Download

The workbook appears in `/Volumes/ust_databricks/social/promo_output/`. It has four sheets:
*Summary*, *Promo vs Social Listening*, *TikTok Search List* and *RedNote Search List*. The
two search lists are deleted by steps 5 and 6.

### 5. TikTok (English, Thai, Vietnamese)

In Chrome, signed in to TikTok: attach the workbook to Claude in Chrome and paste
[prompts/tiktok_promo_search.md](prompts/tiktok_promo_search.md). Claude searches every
item on the *TikTok Search List*, writes the exact videos into the item's language
blocks, and deletes that sheet. It never writes in the Chinese block.

### 6. RedNote (Chinese)

In Chrome, signed in to RedNote (Xiaohongshu); search shows nothing when signed out.
Attach the workbook that came back from step 5 and paste
[prompts/rednote_promo_search.md](prompts/rednote_promo_search.md). Claude searches the
Chinese phrases on the *RedNote Search List*, fills the Chinese block, and deletes that
sheet.

Steps 5 and 6 can run in either order. The finished workbook has two sheets: *Summary* and
*Promo vs Social Listening*.

## What the output means

- **One row per promo item.** Match Status is the item's best result. Beside it,
  *On Trending Social (Mentionlytics)* and *Direct Scraping (TikTok, YouTube & RedNote)*
  show what each source found.
- **Result blocks:** *Trending Social 1–3*, then 3 cells per language: English, Thai,
  Vietnamese (YouTube and TikTok) and Chinese (RedNote only). Each cell links to the post,
  is green for Exact or yellow for Close, and carries the caption as a note.
- **Which posts:** per language, the best performers (views, then engagement) posted in
  the past 2 years. If a language has nothing that recent, its best older posts are used
  and marked `older`.
- `–` = not searched in that language; blank = searched, nothing found.

## Running a month locally

DuckDB, nothing written to Databricks except the AI calls (model serving) and the
YouTube API:

```
python scripts/promo/validate_promo_input.py "UST 2026 NOV PROMO INPUT.xlsx"
python scripts/promo/load_promo_list.py "UST 2026 NOV PROMO INPUT.xlsx"
dbt seed --select seed_promo_item_terms && dbt run --select +int_promo_items_enriched
python scripts/promo/draft_promo_terms.py             # only if terms_source = 'missing' anywhere
dbt run --select int_promo_items_enriched stg_mentionlytics__mentions
python scripts/promo/match_promo_social.py            # --dry-run: keyword pass only, no AI
dbt run --select stg_promo__social_judgments int_promo_social_matches
python scripts/promo/youtube_search.py                # --dry-run: list items + queries, no API
dbt build --select tag:promo
python scripts/promo/export_promo_social_match.py
```

**On real data:** `python scripts/pull_real_snapshot.py` copies the Databricks tables into
`data/real/` (read-only SELECTs; git ignores the folder). Then add
`--vars '{local_data_root: data/real}'` to every dbt command and set
`PROMO_LOCAL_DATA_ROOT=data/real` for the scripts.

**Tests:** `python -m pytest scripts/promo/tests`.

## Credentials

- **AI calls** (draft terms, judge) go to Databricks model serving. Locally they sign in
  through the browser the first time; the everyday `DATABRICKS_TOKEN` is SQL-only and is
  refused. Or set `DATABRICKS_SERVING_TOKEN`.
- **YouTube**: `YOUTUBE_API_KEY` in `.env` locally; secret scope `ust-social`, key
  `youtube-api-key`, on Databricks. The free quota is 10,000 units a day, about 200 per
  item searched.

## Common fixes

| Symptom | Fix |
|---|---|
| Load fails with `schema error(s)` | Run step 2 on the file and fix the errors it lists. |
| An item's terms look wrong (wrong brand, flavor, phrases) | Edit its row in `seeds/seed_promo_item_terms.csv`, set `review_status = reviewed`, commit, rerun. See *Editing the terms* in the dbt doc. |
| A new brand code (like `HB`) appears in descriptions | Add it to `promo_brand_codes` in `dbt_project.yml`, commit, rerun; the month's unreviewed items are re-drafted. |
| YouTube stops with a quota error | Searched items are saved; run again the next day and it continues. |
| An item has no Chinese column results | It has no Chinese search phrase (rows reviewed before October 2026). Add one in the seed. |
| A code change doesn't show up on Databricks | The job runs the `main` branch: merge first. |

## Files

| Path | What it is |
|---|---|
| `scripts/promo/promo_input_schema.py` | the INPUT file's columns and rules (the contract) |
| `scripts/promo/validate_promo_input.py` | checks an INPUT file; also its reader |
| `scripts/promo/load_promo_list.py` | loads the INPUT file (or an old-layout workbook) |
| `scripts/promo/draft_promo_terms.py` | AI-drafted search terms |
| `scripts/promo/match_promo_social.py` | Mentionlytics keyword pass + AI judge |
| `scripts/promo/youtube_search.py` | YouTube search + judge |
| `scripts/promo/export_promo_social_match.py` | writes the output workbook |
| `scripts/promo/promo_common.py` | shared matcher, judge, languages and I/O |
| `scripts/promo/bootstrap_promo_results.py` | one-off: upload a month matched locally to Databricks, so the job finds it done (used for October 2026) |
| `scripts/promo/prompts/` | the three Claude prompts: merge, TikTok, RedNote |
| `scripts/promo/tests/` | pytest suite |
| `scripts/databricks/promo_social_job.yml` | the Databricks job |
| `seeds/seed_promo_item_terms.csv` | reviewed search terms per item |
| `models/staging/promo/`, `int_promo_*`, `mart_promo_social_match` | the dbt models |

## Not built yet

The description file's photos and text are **loaded but not yet used for matching**.
Planned next: a product card per item (pack text, size, pack look, lookalikes) that feeds
the search phrases and the judge, YouTube thumbnails compared with the product photo, the
photo and description on the TikTok and RedNote lists, and every item scraped, with
Mentionlytics shown as a separate Trending flag.
