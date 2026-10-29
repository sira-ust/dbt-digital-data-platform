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
| 5 | TikTok (English, Thai, Vietnamese) + RedNote (Chinese) search, one prompt | Claude in Chrome, by hand |

### 1. Merge the files

Two files come in each month, and their layouts change from month to month, so they are
merged into one workbook in a fixed layout:

1. the promo list, `UST <YYYY> <MON> PROMO.xlsx` (e.g. `UST 2026 NOV PROMO.xlsx`);
2. the description file with photos, `UST <YYYY> <MON> NEW - desc.xlsx`.

Attach both to Claude and paste
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

### 2. Put the photos in their cells, then validate

```
python scripts/promo/photos_in_cells.py "C:/Users/<you>/Downloads/UST 2026 NOV PROMO INPUT.xlsx"
python scripts/promo/validate_promo_input.py "C:/Users/<you>/Downloads/UST 2026 NOV PROMO INPUT.xlsx"
```

Claude can only float the photos over the sheet. `photos_in_cells.py` moves each one
into its `photo` cell (Excel "Place in Cell", as in the description file) and makes the
rows tall enough to see it. It's safe to run twice. The validator warns if photos are
still floating.

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
| draft cards | [draft_product_cards.py](draft_product_cards.py) | AI reads each item's photo and description and drafts its **product card** (see below) |
| dbt | | |
| match social | [match_promo_social.py](match_promo_social.py) | keyword pass over every Mentionlytics post, then the AI judge |
| dbt | | |
| YouTube | [youtube_search.py](youtube_search.py) | searches English, Thai and Vietnamese phrases (never Chinese), the card's first; judges each video against the card, with the product photo next to the thumbnail |
| dbt + tests | | the mart and every promo test; a failing test stops the export |
| export | [export_promo_social_match.py](export_promo_social_match.py) | writes the workbook |

A rerun of the same month is cheap: YouTube results are cached per item and month, and
judged posts are not judged again. An item is searched again when its terms are
re-drafted or it gets a new product card.

### Product cards

For each item with a photo or a description, the model drafts a card: the brand, product
and flavor **as printed on the pack** (e.g. "Vị Sườn Nướng BBQ Brazil / Brazil BBQ Pork
Rib"), the pack and size, the market, what it looks like, and its **lookalikes** (the same
brand's other flavors on the promo, other countries' editions). The card:

- puts its pack-text phrases **first** in the searches, and adds the pack's flavor
  spellings to the match terms;
- is given to the AI judge, which rejects lookalikes (e.g. the US "Mesquite BBQ" Stax can
  for the Vietnamese "Vị Thịt Nướng BBQ" one). For YouTube the judge also sees the product
  photo next to each video's thumbnail;
- is shown, with the photo, on the TikTok and RedNote lists for the hand searches.

Cards are re-drafted when the photo or text changes. An item with neither has no card and
is matched as before. To see a month's cards: `stg_promo__product_cards`.

### 4. Download

The workbook appears in `/Volumes/ust_databricks/social/promo_output/`. It has four sheets:
*Summary*, *Promo vs Social Listening*, *TikTok Search List* and *RedNote Search List*. The
two search lists are deleted by step 5.

### 5. TikTok + RedNote, one prompt

In Chrome, signed in to **TikTok** and to **RedNote on rednote.com** (xiaohongshu.com does
not open for us; RedNote search shows nothing when signed out): attach the workbook to
Claude in Chrome and paste
[prompts/tiktok_rednote_search_prompt.md](prompts/tiktok_rednote_search_prompt.md).

- The *TikTok Search List* (English, Thai, Vietnamese) goes first: exact videos go into
  the item's language blocks, never the Chinese block.
- Then the *RedNote Search List* (Chinese only): exact notes go into the Chinese block.
- **RedNote links need one click from you.** A RedNote link only opens with the
  `xsec_token` key in it, which the browser hides from Claude. When the RedNote list is
  done, Claude shows a box in the rednote tab: click **Copy links** and paste them into the
  chat (or **Download CSV** and attach it), and Claude puts the full links in the workbook.
  The links stay saved in that browser, so if you were away, attach the returned file with
  the same prompt and it shows the box again.
- Both lists show each item's product card and photo, and lookalike packs are thrown out.
- Claude deletes each list row when that item is done. If it stops before the end,
  attach the file it gave back with the same prompt: it continues from the first row left.

The finished workbook has two sheets: *Summary* and *Promo vs Social Listening*.

### 6. Put the photos in their cells (after step 5)

The export's photos float inside their cells, so that the hand search (which edits the file
with openpyxl) keeps them. They are set to "move and size with cells", the header filter
covers the Photo column, and every row has the same height, so a sort or filter keeps each
photo on its item. Once step 5 is done, place them inside their cells for good, where they
behave like the cell's value (copying rows, other spreadsheet apps):

```
python scripts/promo/photos_in_cells.py "UST_NOV_Promo_Social_Listening_Match.xlsx" --sheet "Promo vs Social Listening" --column Photo
```

### Photos on an older output

Since 2026-10-28 the export puts each item's photo in a **Photo** column beside its name.
For a workbook exported before that (November's first run), add them from the INPUT file,
matched by item number:

```
python scripts/promo/add_photos_to_output.py "UST_NOV_Promo_Social_Listening_Match.xlsx" "UST 2026 NOV PROMO INPUT.xlsx"
```

With no Photo column, it adds one after the last column, so no formula or link moves. Safe
to run twice; run it before or after step 5, then do step 6.

## What the output means

- **One row per promo item**, with the item's product **photo** beside its name (when the
  INPUT file has one). Match Status is the item's best result. Beside it,
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
python scripts/promo/draft_product_cards.py           # --dry-run: list items; --only 37545 37548: a test
dbt run --select stg_promo__product_cards int_promo_items_enriched stg_mentionlytics__mentions
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
| `scripts/promo/photos_in_cells.py` | moves an INPUT file's floating photos into their cells |
| `scripts/promo/add_photos_to_output.py` | adds the photos to an output workbook exported before the Photo column |
| `scripts/promo/load_promo_list.py` | loads the INPUT file (or an old-layout workbook) |
| `scripts/promo/draft_promo_terms.py` | AI-drafted search terms |
| `scripts/promo/draft_product_cards.py` | AI-drafted product cards, from the photo and description |
| `scripts/promo/match_promo_social.py` | Mentionlytics keyword pass + AI judge |
| `scripts/promo/youtube_search.py` | YouTube search + judge |
| `scripts/promo/export_promo_social_match.py` | writes the output workbook |
| `scripts/promo/promo_common.py` | shared matcher, judge, languages and I/O |
| `scripts/promo/bootstrap_promo_results.py` | one-off: upload a month matched locally to Databricks, so the job finds it done (used for October 2026) |
| `scripts/promo/prompts/` | the two Claude prompts: the monthly merge, and the TikTok + RedNote search |
| `scripts/promo/tests/` | pytest suite |
| `scripts/databricks/promo_social_job.yml` | the Databricks job |
| `seeds/seed_promo_item_terms.csv` | reviewed search terms per item |
| `models/staging/promo/`, `int_promo_*`, `mart_promo_social_match` | the dbt models |

## Not built yet

Every item scraped, with Mentionlytics shown as a separate Trending flag instead of
deciding which items are scraped. Today Mentionlytics still goes first: items it matched
are scraped only if they are UST's own brands.
