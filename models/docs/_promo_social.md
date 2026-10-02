{% docs promo_social_match %}

## Monthly promo × social match

Each month's promo workbook (`UST <YYYY> <MON> NEW PROMO.xlsx`, sheets `<MON> NEW` and
`<MON> PROMO`) is matched against everything social listening has collected. Items it
can't find are searched on YouTube, and then on TikTok by hand. The output is
`UST_<MON>_Promo_Social_Listening_Match.xlsx`, in the layout of the October 2026 workbook.

### How an item gets its rows

1. **Terms.** `seed_promo_item_terms` holds each item's brand, product and flavor, plus
   search terms in English, Thai and Vietnamese and *negative* terms. NAV has no brand
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
3. **YouTube.** `youtube_search.py` runs only for branded items with *no* social listening
   row. It runs each item's `search_queries` (up to 3), applies the same keyword rule and
   judge to title, description and tags, and keeps the top 1–3 Exact videos by views.
4. **The mart.** `mart_promo_social_match` builds the rows. An item with an Exact post shows
   only Exact posts; otherwise it shows its Close posts, then YouTube, then one `Unmatched` row.
5. **TikTok, by hand.** The workbook's *TikTok Search List* sheet lists every branded item
   social listening didn't match. Open the workbook in Claude in Chrome with
   `scripts/prompts/tiktok_promo_search.md`; Claude adds TikTok rows under each item and
   deletes that sheet. TikTok has no search API open to a for-profit company: the Research
   API is academic-only and the Commercial Content API covers EU ads only.

### Running a new month on Databricks

Drop the workbook into `/Volumes/ust_databricks/social/promo_landing/`. The job
`ust-promo-social-match` (`scripts/databricks/promo_social_job.yml`) runs in this order:
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
