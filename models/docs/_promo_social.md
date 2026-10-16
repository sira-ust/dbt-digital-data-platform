{% docs promo_social_match %}

## Monthly promo × social match

Each month's promo workbook (`UST <YYYY> <MON> NEW PROMO.xlsx`, sheets `<MON> NEW` and
`<MON> PROMO`) is matched against everything social listening has collected. Items it
can't find are searched on YouTube, and then on TikTok by hand. The output is
`UST_<MON>_Promo_Social_Listening_Match.xlsx`, in the layout of the October 2026 workbook.

### How an item gets its rows

1. **Terms.** `seed_promo_item_terms` holds each item's brand, product and flavor, plus
   search terms in English, Thai, Vietnamese and Chinese and *negative* terms. NAV has no brand
   column and the promo text is truncated, so this reviewed file is the source of truth.
   Items not in it get an LLM draft (`draft_promo_terms.py`) that is used until someone
   reviews it.
2. **Social listening.** `match_promo_social.py` checks every raw Mentionlytics post (title
   and content, not the enrichment tags). A post becomes a candidate when it names the
   brand plus the product or flavor. The AI judge (`promo_judge_model`, majority of
   `promo_judge_votes` calls) then rules on each candidate:
   - **exact**: names this brand, product and, if the item has one, flavor;
   - **close**: about this brand's product but the flavor isn't stated, or the same product
     in another format (the seasoned version of a plain rice paper);
   - **reject**: a different named flavor or edition, "new flavor" left unnamed, a recipe that
     doesn't name the flavor, a bare hashtag, a sale post, news, or the brand word meaning
     something else.

   The judge can lower the keyword level but never raise it. An Exact row always has the
   brand, product and flavor terms in its own text (`assert_promo_exact_has_terms`).
3. **YouTube.** `youtube_search.py` runs for branded items with *no* social listening
   row, and for every own-brand item. It runs each item's `search_queries` (up to 3),
   applies the same keyword rule and judge to title, description and tags, and keeps the
   top 1–3 Exact videos by views, then engagement (likes + comments). Only videos posted
   in the past 2 years (`promo_scraped_max_age_months`, counted back from the promo month)
   count when the item has any; when it has none, its older videos are used instead and
   their Match Note starts "Older than 2 years".
4. **The mart.** `mart_promo_social_match` builds the rows. An item with an Exact post shows
   only Exact posts; otherwise it shows its Close posts, then YouTube, then one `Unmatched` row.
   UST's own brands show their social listening posts *and* their YouTube videos.
   In the workbook, **Match Status** is the item's status (the better of the two sources),
   the same on every row of the item. Beside it, **On Trending Social (Mentionlytics)** and
   **Direct Scraping (TikTok & YouTube)** show what each source found for the item, and each
   row's **Source** says which of the two it came from.
5. **TikTok, by hand.** The workbook's *TikTok Search List* sheet lists every branded item
   social listening didn't match. Open the workbook in Claude in Chrome with
   `scripts/prompts/tiktok_promo_search.md`; Claude adds TikTok rows under each item and
   deletes that sheet. TikTok has no search API open to a for-profit company: the Research
   API is academic-only and the Commercial Content API covers EU ads only.

### Running a new month on Databricks

Upload the workbook to `/Volumes/ust_databricks/social/promo_landing/`, then open the
job `ust-promo-social-match` (`scripts/databricks/promo_social_job.yml`) and click
**Run now** — it is started by hand, not by the upload. It runs in this order:
load → dbt → draft terms → dbt → match social → dbt → YouTube → dbt (with all promo tests)
→ export. The workbook lands in `/Volumes/ust_databricks/social/promo_output/`. Then do
the TikTok step.

New items get LLM-drafted terms automatically. To review them, see *Editing the terms*.

### Running a month locally (DuckDB)

```
python scripts/load_promo_list.py "UST 2026 OCT NEW PROMO.xlsx"
dbt seed --select seed_promo_item_terms && dbt run --select +int_promo_items_enriched
python scripts/draft_promo_terms.py             # only if terms_source = 'missing' anywhere
dbt run --select int_promo_items_enriched stg_mentionlytics__mentions
python scripts/match_promo_social.py            # --dry-run: keyword pass only, no LLM
dbt run --select stg_promo__social_judgments int_promo_social_matches
python scripts/youtube_search.py                # --dry-run: list items + queries, no API
dbt build --select tag:promo
python scripts/export_promo_social_match.py
```

**To test on real data without writing to Databricks:** run
`python scripts/pull_real_snapshot.py` (read-only SELECTs into `data/real/`, which git
ignores). Then add `--vars '{local_data_root: data/real}'` to every dbt command and set
`PROMO_LOCAL_DATA_ROOT=data/real` for the scripts.

**Credentials:**
- Local AI calls sign in through the browser. The everyday `DATABRICKS_TOKEN` PAT is
  SQL-only and model serving refuses it.
- The YouTube key comes from `YOUTUBE_API_KEY` in `.env` locally, or secret scope
  `ust-social` / `youtube-api-key` on Databricks.

### Editing the terms

Edit `seeds/seed_promo_item_terms.csv`: one row per item, terms separated by `|`. Then
set `review_status = reviewed` and commit. How terms match:

- **Thai, Japanese, Chinese and Korean terms** match anywhere in the text, because those
  scripts don't put spaces between words.
- **All other terms match whole words only.** `cozy` doesn't fire inside `#cozytea`, and
  `sting` doesn't fire inside `stingray`.
- **A multi-word term without Vietnamese accents also matches the accented spelling.**
  `chuon chuon` finds `Chuồn Chuồn`.
- **Single words and accented terms match only as written.** `cam` (orange) must not find
  `cảm ơn` (thank you).
- **When the brand IS the product** (Fanta, Sting, Kit Kat, Ginseng Up), list the brand
  under `product_terms` too, so a post naming the brand and flavor can be Exact.
- **Hashtag-only posts need hashtag terms.** `#oragonsiligarlicoil` isn't matched by
  `oragon`.
- **Changes take effect on the next run.** A new term can create new candidates; already
  judged pairs aren't re-judged unless `JUDGE_PROMPT_VERSION` changes.

To add drafts to the seed for review: `python scripts/draft_promo_terms.py --to-seed`.

**Chinese.** Since prompt v3, every draft also carries Chinese terms (Simplified, and
Traditional where it differs) and its third search phrase is in Chinese, so YouTube and
the TikTok list search in Chinese too, at no extra quota (still 3 searches per item).
Rows reviewed before that (October 2026) have no Chinese: add the terms and a Chinese
phrase by hand if an item needs them.

### Brand codes and UST's own brands

UST writes codes into item descriptions. The var `promo_brand_codes` in `dbt_project.yml` lists them:

| Code | Means | Searched as |
|---|---|---|
| HB | Honeybee (own brand) | honeybee, ฮันนี่บี |
| DF | Dragonfly (own brand) | dragonfly; in Vietnam it is sold as Chuồn Chuồn |
| CG | Chung Guang (own brand) | chung guang |
| FZ | frozen (not a brand) | — |
| DFZ | discontinued frozen (not a brand) | — |

`draft_promo_terms.py` gives the LLM this list, and a description carrying a brand code
always gets that brand and its terms. So "FZ DF SESAME DONUT" is a Dragonfly item and
"HB" is never guessed.

**Own brands are matched AND always scraped.** An item whose brand is an own brand
(`is_own_brand`, matched on the seed's `aliases`) is matched against Mentionlytics like
any brand, and also goes to YouTube and the TikTok list even when Mentionlytics found
posts. Mentionlytics tracks two broad F&B keyword sets that rarely name UST's own brands,
so scraping is where most own-brand posts come from. Other brands are scraped only when
Mentionlytics found nothing.

**Adding a code mid-month.** Add it to `promo_brand_codes`, commit, and run the job again. Every draft
records the version it was made with (model, prompt, and a fingerprint of the code
list), so the run re-drafts the latest month's unreviewed items whose draft is out of
date, and YouTube searches each re-drafted item again. Reviewed seed rows and older
months are never re-drafted: edit reviewed rows by hand.

### Known false-positive patterns

| Brand word | Also means | Handled by |
|---|---|---|
| cozy / cosy | the English adjective (cafés, rooms, games) | needs tea/trà/ชา or a Cozy hashtag; negative terms; judge |
| sting | the singer, the wrestler, insect stings, police stings | negative terms; whole-word matching; judge |
| hoshi | SEVENTEEN's Hoshi, "star" in Japanese, restaurants | `#seventeen`, `#svt`, `#kpop` negatives |
| joyluck | *The Joy Luck Club*, restaurants and casinos | negative terms |
| bento | Japanese lunch boxes and bento cakes; Bento crab sticks | negative terms; judge |
| chuồn chuồn | the dragonfly itself; other dragonfly-art brands | negative terms; the brand's other products (spring rolls) are rejected |
| fanta | the brand's many other flavors and the new "Fantasy" line | judge rejects other named flavors and "new flavor" |
| สายน้ำผึ้ง | the Sai Nam Phueng orange variety on its own | brand required |
| honeybee | bees and honey | `hb` and `honey bee` dropped from brand terms |

### Known differences from the October 2026 hand-built workbook

These were measured on the real Databricks corpus: 53,601 posts, Feb 20 – Sep 29.
- **Chuồn Chuồn** has two more Close posts than October. Both are the same seasoned
  rice paper that October already listed as Close.
- **Bento** keeps October's Close from the bachhoaxanh article. The YouTube comment
  October also counted names *grilled-squid* flavor, so it's rejected for all four flavors.
- **TikTok rows** (Cozy teas, Tean's, Oragon, Tasco, Ginseng Up Cola in October) come only
  from the manual TikTok step.

{% enddocs %}
