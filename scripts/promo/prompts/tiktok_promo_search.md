# TikTok search — monthly promo social match

Paste everything below the line into Claude in Chrome, and attach the month's
`UST_<MON>_Promo_Social_Listening_Match.xlsx` (the file the pipeline wrote). Stay
signed in to TikTok in that Chrome window. The rules here are the same ones the
pipeline applies to social listening posts and YouTube videos, so every source in
the workbook means the same thing by "Exact".

---

You are adding TikTok videos to a promo social-listening workbook. Work through the
attached workbook and give me the updated file back.

## What to search

The sheet **TikTok Search List** has one row per promo item to search. For each row:

1. Search **each line of Search Phrases** on TikTok (the **TikTok Search Link** opens the
   first one). Each line starts with its language in brackets, e.g. `[Thai] แฟนต้า องุ่น`:
   search only the text after the brackets, and remember the language: it decides where
   the video goes on the main sheet. Look at the top results for each search, scrolling
   once or twice.
2. Keep a video only if it is an **exact match**. Its caption or on-screen hashtags must name
   - the **brand**: one of the *Must Mention (brand)* words, any spelling, including Thai,
     Vietnamese or Chinese script or a hashtag; and
   - the **product**: what the item is, e.g. tea, juice, energy drink, rice paper; and
   - the **flavor / variant**: one of the *Flavor Words*. Skip this check when the column says
     "(no flavor to require)".
3. Throw a video out when any of these apply:
   - it names a different flavor or edition of the brand, or says "new flavor" without
     naming it;
   - the brand word means something else: a person, K-pop idol, film, restaurant, or an
     ordinary word like "cozy";
   - any phrase in **Exclude If** appears;
   - the brand appears only as one hashtag among many, with no product talk.
   A recipe or drink mix still counts when it names this exact item, e.g. "Red Bull mixed
   with Deedo Cantaloupe".
4. Prefer videos **posted in the past 2 years** (counted back from the start of the
   promo month, e.g. on or after 2024-11-01 for a NOV 2026 workbook). If the post date
   isn't shown in the results, open the video to check it. If a language has **no** exact
   video from the past 2 years, take its older ones instead and mark them `older` (see
   below). Decide this per language, not per item.
5. **Per language**, take the **top 3 by performance** from the videos you kept: most likes
   first; for a tie, the one with more comments. Fewer is fine. Never pad with weaker
   matches. Keep every language's results: a strong English video must never push out a
   Thai or Vietnamese one. A video that two phrases both found counts once, under the
   first phrase that found it.

### UST's own brands

Item descriptions use codes. **HB** = Honeybee, **DF** = Dragonfly, **D FZ** = Dragonfly
frozen, **CG** = Chung Guang: these are UST's own brands. **FZ** or **FROZEN** (frozen) and
**DFZ** (discontinued frozen) are not brands, so "FZ DF SESAME DONUT" is a frozen
Dragonfly item. Own-brand items are always
on the search list, even when trending social (Mentionlytics) already found posts for
them: their **Current Status** then says so, e.g. `Close (On Trending Social)`. Search
them like any other brand:
- **Honeybee**: also search the Thai spelling ฮันนี่บี.
- **Dragonfly**: in Vietnam it is sold as **Chuồn Chuồn**, so search that name too. A
  video counts when it names either Dragonfly or Chuồn Chuồn together with the product.
  "Chuồn chuồn" on its own also means the insect, so it is not enough.

### Frozen items with no brand

A row whose **Must Mention (brand)** starts with `(no brand: frozen product)` is a frozen
item with no brand (e.g. "FZ PURE SUGARCANE JUICE"). Search its phrases the same way, but
keep a video only when:
- it names the **product** and, when the item has one, the **flavor / variant**; and
- it shows a **frozen, packaged** product: a frozen pack being bought, unboxed, heated or
  reviewed, whatever its brand.

Throw out homemade recipes, street-food stalls, restaurant dishes and fresh (not frozen)
versions, even when the dish is the same. These videos can't confirm a brand, so they are
**`Close`**, never `Exact`: give their cells the yellow Close fill, and start their cell
note with `No brand to match (frozen item); frozen packaged product named in video.`

## How to write each video into "Promo vs Social Listening"

That sheet has **one row per item**: find it by **Item No.** in column B. Never add rows.

After the item's columns (A–I) come the **result blocks**, three cells each:
*Trending Social 1–3*, then one block per search language, e.g. *English 1–3*,
*Thai 1–3*, *Vietnamese 1–3*, *Chinese 1–3*. Put each video in the block of **the
language of the phrase that found it**, in the first empty cell of that block. **Never
write in the Chinese block**: Chinese is searched only on RedNote, in a separate step,
so this list has no Chinese phrases. A cell
holding `–` means the item was not searched in that language; you may overwrite it if
you did search that language.

**A full block.** If the language's three cells already hold results (YouTube videos the
pipeline found), compare likes: a YouTube cell shows them as `… · 900 likes · …`. Your
video replaces the result with the fewest likes only if yours has more; a YouTube cell
without a likes figure counts as 0. Otherwise leave the block as it is. Never move a
result into another language's block to make room.

**Each result cell:**
- **Text**: `TikTok · <likes> likes · <post date>`, e.g. `TikTok · 3,706 likes · 2025-02-14`.
  Likes as TikTok shows them; if it shows only an abbreviation, open the video for the
  exact number, and if none exists write it with a tilde: `~3.7K likes`. Post date as
  `YYYY-MM-DD`, or `YYYY-MM` if TikTok shows only a month; leave it out if unknown. Add
  ` · older` at the end for a video older than 2 years (step 4).
- **Link**: the cell hyperlinks to the video's own URL,
  `https://www.tiktok.com/@handle/video/<id>`, never a search or discover page. Blue text
  `0563C1`, underlined, Arial 10.
- **Fill**: green `C6EFCE` for an Exact video, yellow `FFEB9C` for a Close one (frozen items
  with no brand).
- **Note** (a cell comment), four parts separated by blank lines: the product name as the
  video writes it, native script kept with English in parentheses, e.g.
  `Trà Vải Cozy (Cozy Lychee Tea)`; the creator's handle with the `@`, plus ` (brand)` if
  it is the brand's own account; the full caption, hashtags included; and
  `Brand + product/flavor named in video.` plus any caveat, e.g. pack size differs or it is
  the powder version. For an older video, start the last part with
  `Older than 2 years: no recent video was found.`

**Then update the item's columns:**

| Column | Value |
|---|---|
| F Match Status | the item's best status across everything on its row: `Exact` if any result is Exact, else `Close`. Bold; Exact is dark green text `006100` on green fill `C6EFCE`, Close is brown text `9C5700` on yellow fill `FFEB9C`. An item that was Unmatched stops being grey: use black text in A–E and I |
| G On Trending Social (Mentionlytics) | unchanged |
| H Direct Scraping (TikTok, YouTube & RedNote) | the best scraped status, YouTube, TikTok and RedNote together, styled like F |
| I Posts | a formula: leave it alone, it recounts by itself |

## When you are done

1. Delete the **TikTok Search List** sheet. Leave the **RedNote Search List** sheet if it
   is still there: the RedNote step deletes it. Once both are gone the workbook has exactly
   two sheets, in this order: *Summary* (first) and *Promo vs Social Listening*.
2. On the **Summary** sheet, leave every formula alone; they recount automatically. Then
   in **Unmatched promo items (no post found)**, delete the rows of items you just matched,
   so the list keeps only items with no post at all. Keep the grey note under the list.
3. On *Promo vs Social Listening*, keep the header row, the freeze at D2 and the filter on
   the header row. The sheet still has exactly one row per promo item.
4. Save as the same file name and give it back to me, with a list of every item you
   searched: for each, which phrases you searched (by language) and how many exact videos
   you kept per language, including the ones where you found none.
