# RedNote search — monthly promo social match

Paste everything below the line into Claude in Chrome, and attach the month's
`UST_<MON>_Promo_Social_Listening_Match.xlsx`. You can attach it before or after the
TikTok step (`tiktok_promo_search.md`); each step writes only its own cells. Stay
signed in to RedNote (Xiaohongshu, 小红书) in that Chrome window: its search shows
nothing to a signed-out visitor. The rules here are the same ones the pipeline applies to
social listening posts and YouTube videos, so every source in the workbook means the same
thing by "Exact".

RedNote is the only place the pipeline searches in Chinese. YouTube and TikTok search no
Chinese phrases, so the workbook's *Chinese* block holds RedNote posts and nothing else.

---

You are adding RedNote (Xiaohongshu, 小红书) posts to a promo social-listening workbook.
Work through the attached workbook and give me the updated file back.

## What to search

The sheet **RedNote Search List** has one row per promo item to search. Every phrase on it
is Chinese. For each row:

1. Search **each line of Search Phrases** on RedNote (the **RedNote Search Link** opens the
   first one). Each line starts with `[Chinese]`: search only the text after the brackets.
   Look at the top results for each search (notes, both image and video), scrolling once
   or twice.
2. Keep a note only if it is an **exact match**. Its title, text or hashtags (including
   text written on the note's images) must name
   - the **brand**: one of the *Must Mention (brand)* words, in any spelling: Latin
     letters, Simplified or Traditional Chinese, or a hashtag. Chinese posts often write the
     brand in Latin letters ("Cozy 荔枝茶"); that counts. Never accept a Chinese brand name
     that is not on the list because it seems likely; and
   - the **product**: what the item is, e.g. tea, juice, energy drink, rice paper; and
   - the **flavor / variant**: one of the *Flavor Words*. Skip this check when the column says
     "(no flavor to require)".
3. Throw a note out when any of these apply:
   - it names a different flavor or edition of the brand, or says "new flavor" (新口味)
     without naming it;
   - the brand word means something else: a person, idol, film, restaurant, or an ordinary
     word;
   - any phrase in **Exclude If** appears;
   - the brand appears only as one hashtag among many, with no product talk;
   - it is a shop listing or an ad with no post around it (a product card from RedNote's
     own store, or a sponsored placement that is only a price).
   A recipe or drink mix still counts when it names this exact item.
4. Prefer notes **posted in the past 2 years** (counted back from the start of the promo
   month, e.g. on or after 2024-11-01 for a NOV 2026 workbook). RedNote often shows a
   relative date ("3天前", "昨天") or only month and day ("10-12" means this year): turn
   it into a date. If the date isn't shown, open the note to check it. If the item has
   **no** exact note from the past 2 years, take its best older ones instead and mark them
   `older` (see below).
5. Take the **top 3 by performance** from the notes you kept: most likes (赞) first; for a
   tie, the one with more collects (收藏). Fewer is fine. Never pad with weaker matches. A
   note that two phrases both found counts once.

### UST's own brands

Item descriptions use codes. **HB** = Honeybee, **DF** = Dragonfly, **D FZ** = Dragonfly
frozen, **CG** = Chung Guang: these are UST's own brands. **FZ** or **FROZEN** (frozen) and
**DFZ** (discontinued frozen) are not brands, so "FZ DF SESAME DONUT" is a frozen
Dragonfly item. Own-brand items are always on the search list, even when trending social
(Mentionlytics) already found posts for them: their **Current Status** then says so, e.g.
`Close (On Trending Social)`. Search them like any other brand, and accept only the brand
spellings in *Must Mention (brand)*.

### Frozen items with no brand

A row whose **Must Mention (brand)** starts with `(no brand: frozen product)` is a frozen
item with no brand (e.g. "FZ PURE SUGARCANE JUICE"). Search its phrases the same way, but
keep a note only when:
- it names the **product** and, when the item has one, the **flavor / variant**; and
- it shows a **frozen, packaged** product (速冻, 冷冻): a frozen pack being bought,
  unboxed, heated or reviewed, whatever its brand.

Throw out homemade recipes, street-food stalls, restaurant dishes and fresh (not frozen)
versions, even when the dish is the same. These notes can't confirm a brand, so they are
**`Close`**, never `Exact`: give their cells the yellow Close fill, and start their cell
note with `No brand to match (frozen item); frozen packaged product named in post.`

## How to write each note into "Promo vs Social Listening"

That sheet has **one row per item**: find it by **Item No.** in column B. Never add rows.

After the item's columns (A–I) come the **result blocks**, three cells each. Write only in
the **Chinese** block (*Chinese 1–3*), in its first empty cells. Never touch any other
block. A cell holding `–` means the item had no Chinese phrase; you may overwrite it only
if you did search the item. If the item's Chinese cells already hold three results (the
attached workbook already went through this step), replace the one with the fewest likes
only if your note has more.

**Each result cell:**
- **Text**: `RedNote · <likes> likes · <post date>`, e.g. `RedNote · 1,204 likes · 2025-08-19`.
  Likes as RedNote shows them; it abbreviates large numbers in 万 (1.2万 = 12,000): write
  those with a tilde, `~12,000 likes`. Post date as `YYYY-MM-DD`; leave it out if unknown.
  Add ` · older` at the end for a note older than 2 years (step 4). The text must start
  with `RedNote · `: the Summary counts RedNote results by it.
- **Link**: the cell hyperlinks to the note's own URL, as the address bar shows it when the
  note is open (`https://www.xiaohongshu.com/explore/<note id>`, plus any `?xsec_token=…`
  it carries: without it the note may not open for someone else). Never a search page.
  Blue text `0563C1`, underlined, Arial 10.
- **Fill**: green `C6EFCE` for an Exact note, yellow `FFEB9C` for a Close one (frozen items
  with no brand).
- **Note** (a cell comment), four parts separated by blank lines: the product name as the
  post writes it, Chinese kept with English in parentheses, e.g. `芬达葡萄味 (Fanta Grape)`;
  the author's name plus ` (brand)` if it is the brand's own account; the note's title and
  text, hashtags included, translated into English after the original; and
  `Brand + product/flavor named in post.` plus any caveat, e.g. pack size differs, or the
  brand is named only in the image text. For an older note, start the last part with
  `Older than 2 years: no recent post was found.`

**Then update the item's columns:**

| Column | Value |
|---|---|
| F Match Status | the item's best status across everything on its row: `Exact` if any result is Exact, else `Close`. Bold; Exact is dark green text `006100` on green fill `C6EFCE`, Close is brown text `9C5700` on yellow fill `FFEB9C`. An item that was Unmatched stops being grey: use black text in A–E and I |
| G On Trending Social (Mentionlytics) | unchanged |
| H Direct Scraping (TikTok, YouTube & RedNote) | the best scraped status, YouTube, TikTok and RedNote together, styled like F |
| I Posts | a formula: leave it alone, it recounts by itself |

## When you are done

1. Delete the **RedNote Search List** sheet. Leave the **TikTok Search List** sheet if it
   is still there: the TikTok step deletes it. Once both are gone the workbook has exactly
   two sheets, in this order: *Summary* (first) and *Promo vs Social Listening*.
2. On the **Summary** sheet, leave every formula alone; they recount automatically. Then
   in **Unmatched promo items (no post found)**, delete the rows of items you just matched,
   so the list keeps only items with no post at all. Keep the grey note under the list.
3. On *Promo vs Social Listening*, keep the header row, the freeze at D2 and the filter on
   the header row. The sheet still has exactly one row per promo item.
4. Save as the same file name and give it back to me, with a list of every item you
   searched: for each, which phrases you searched and how many exact notes you kept,
   including the ones where you found none.
