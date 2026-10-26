{% docs promo_social_match %}

## Monthly promo × social match

Each month's promo list (`<MON> NEW` and `<MON> PROMO`), merged with the month's
description file into one INPUT workbook (see *Running it*), is matched against
everything social listening has collected. Items it
can't find are searched on YouTube, then on TikTok and RedNote (Xiaohongshu) by hand.
Chinese phrases are searched only on RedNote; the other languages only on YouTube and
TikTok. The output is
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
   **except the Chinese ones** (those go to RedNote, step 6),
   applies the same keyword rule and judge to title, description and tags, and keeps the
   top 1–3 Exact videos **per search language** (the script of the phrase that found the
   video: English, Thai, Vietnamese; a Khmer or Japanese phrase is skipped, Japanese read from its kana before checking for Chinese, since kanji are Chinese characters) by views, then engagement (likes +
   comments), so an English search's view counts never crowd out the Thai or Vietnamese
   finds. Chinese videos an earlier search stored are dropped in `int_promo_scraped_matches`. Only videos posted in the past 2 years (`promo_scraped_max_age_months`, counted
   back from the promo month) count when the item-language has any; when it has none, its
   older videos are used instead and are marked "older".
4. **The mart.** `mart_promo_social_match` holds every match, one row per post. An item with
   an Exact post shows only Exact posts; otherwise its Close posts, then YouTube, then one
   `Unmatched` row. UST's own brands show their social listening posts *and* their YouTube
   videos. **The workbook pivots it wide: one row per item.** Match Status is the item's
   status (the better of the two sources); beside it, **On Trending Social (Mentionlytics)**
   and **Direct Scraping (TikTok, YouTube & RedNote)** show what each source found, and **Posts**
   counts the results. Then the results: *Trending Social 1–3*, and a block of 3 cells per
   search language. A result cell is clickable, coloured by status, and carries the caption
   as a cell note; `–` means the item was not searched in that language. The *Chinese*
   block is left blank for the RedNote step to fill.
5. **TikTok, by hand.** The workbook's *TikTok Search List* sheet lists every branded item
   social listening didn't match, each phrase tagged with its language (no Chinese). Open the workbook in
   Claude in Chrome with `scripts/promo/prompts/tiktok_promo_search.md`; Claude writes each TikTok
   video into its language block on the item's row and deletes that sheet. TikTok has no search API open to a for-profit company: the Research
   API is academic-only and the Commercial Content API covers EU ads only.
6. **RedNote, by hand.** The *RedNote Search List* sheet lists the same items, with their
   Chinese phrases only; an item with no Chinese phrase is left off. Open the workbook in
   Claude in Chrome, signed in to RedNote, with `scripts/promo/prompts/rednote_promo_search.md`.
   Claude writes up to 3 Exact notes into the item's *Chinese* block, by likes, and deletes
   that sheet. RedNote has no public search API either, and search works only when signed in.
   The TikTok and RedNote steps can run in either order: each writes only its own blocks.

### Running it

The monthly steps (merge the files into the INPUT workbook, validate, upload, run the job,
then TikTok and RedNote by hand), local runs, credentials and common fixes are in the
runbook: **`scripts/promo/README.md`**.

The INPUT workbook is the month's promo list merged with its description file (photos,
notes, selling points) into one fixed layout, `scripts/promo/promo_input_schema.py`, so
the pipeline never depends on how UST laid out that month's files. Its extra columns
are loaded (`photo_path` for the photos) but not used for matching yet.

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

To add drafts to the seed for review: `python scripts/promo/draft_promo_terms.py --to-seed`.

**Chinese.** Since prompt v3, every draft also carries Chinese terms (Simplified, and
Traditional where it differs) and its third search phrase is in Chinese. Since
2026-10-23 that phrase is searched **only on RedNote**: YouTube and TikTok skip it, so a
YouTube search costs ~2 searches per item, not 3. Chinese terms still count for matching
everywhere (a Chinese caption on TikTok or YouTube still matches). Rows reviewed before v3
(October 2026) have no Chinese phrase, so they are left off the RedNote list: add the terms
and a Chinese phrase by hand if an item needs them.

### Brand codes and UST's own brands

UST writes codes into item descriptions. The var `promo_brand_codes` in `dbt_project.yml` lists them:

| Code | Means | Searched as |
|---|---|---|
| HB | Honeybee (own brand) | honeybee, ฮันนี่บี |
| DF | Dragonfly (own brand) | dragonfly; in Vietnam it is sold as Chuồn Chuồn |
| D FZ | Dragonfly frozen (own brand, frozen) | as DF |
| CG | Chung Guang (own brand) | chung guang |
| FZ, FROZEN | frozen (not a brand) | as a frozen product, see below |
| DFZ | discontinued frozen (not a brand) | as a frozen product, see below |

The list is kept ASCII-only in `dbt_project.yml` (non-English terms as `\u` escapes):
dbt reads that file in the system encoding, which on Windows cannot decode some Thai
bytes.

`draft_promo_terms.py` gives the LLM this list, and a description carrying a brand code
always gets that brand and its terms. So "FZ DF SESAME DONUT" is a Dragonfly item and
"HB" is never guessed.

**Own brands are matched AND always scraped.** An item whose brand is an own brand
(`is_own_brand`, matched on the list's `aliases`) is matched against Mentionlytics like
any brand, and also goes to YouTube and the TikTok list even when Mentionlytics found
posts. Mentionlytics tracks two broad F&B keyword sets that rarely name UST's own brands,
so scraping is where most own-brand posts come from. Other brands are scraped only when
Mentionlytics found nothing.

**Frozen items with no brand are scraped as frozen products.** A frozen code sets
`pack_format = frozen` (`is_frozen`). An item that is frozen but has no brand (e.g.
"FZ PURE SUGARCANE JUICE") still gets product terms and search phrases, goes to YouTube
and the TikTok list, and a video counts when it names a word for frozen
(`promo_frozen_terms`) plus the product and shows a frozen, packaged pack. There is no
brand to confirm, so these rows are **Close**, never Exact.

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
  from the manual TikTok step, and the Chinese block only from the manual RedNote step.

{% enddocs %}
