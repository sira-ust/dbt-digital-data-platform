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

1. Open the **TikTok Search Link**, then also search each line of **Search Phrases**.
   One phrase is in Chinese (e.g. `芬达 葡萄`): search it like the others. Look at the top
   results for each search, scrolling once or twice.
2. Keep a video only if it is an **exact match**. Its caption or on-screen hashtags must name
   - the **brand**: one of the *Must Mention (brand)* words, any spelling, including Thai,
     Vietnamese or Chinese script or a hashtag. A Chinese caption often writes the brand in
     Latin letters ("Cozy 荔枝茶"); that counts; and
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
4. From the videos you kept, take the **top 3 by likes**. Fewer is fine. Never pad the list
   with weaker matches.

### UST's own brands

Item descriptions use codes. **HB** = Honeybee, **DF** = Dragonfly, **CG** = Chung Guang:
these are UST's own brands. **FZ** (frozen) and **DFZ** (discontinued frozen) are not
brands, so "FZ DF SESAME DONUT" is a frozen Dragonfly item. Own-brand items are always
on the search list, even when trending social (Mentionlytics) already found posts for
them: their **Current Status** then says so, e.g. `Close (On Trending Social)`. Search
them like any other brand:
- **Honeybee**: also search the Thai spelling ฮันนี่บี.
- **Dragonfly**: in Vietnam it is sold as **Chuồn Chuồn**, so search that name too. A
  video counts when it names either Dragonfly or Chuồn Chuồn together with the product.
  "Chuồn chuồn" on its own also means the insect, so it is not enough.

## How to write each video into "Promo vs Social Listening"

Find the item's rows on that sheet. Its **Item No.** matches column B.

- If the item's only row says **Unmatched**, overwrite that row with your first video and
  insert the others **directly below it**.
- If the item already has rows (trending social posts or YouTube videos), insert your
  rows **directly below its last row**.
- Copy columns A–E (Promo Sheet, Item No., Promo Item, Size, Promo Code) from the item's
  existing row, unchanged.
- Formatting, copied from the item's existing row: Arial 10, thin grey borders, top-aligned
  and wrapped, row height 39.75. Every other item is shaded light blue `EEF3F8` so an item's
  rows read as one block: if the item's row is shaded, shade your new rows the same; if not,
  leave them unshaded. A row you overwrite from Unmatched stops being grey: use black text.

Fill the other columns like this:

| Column | Value |
|---|---|
| F Match Status | the ITEM's status, the same on every row of the item: `Exact` if any of its rows is Exact, else `Close`. Bold; Exact is dark green text `006100` on green fill `C6EFCE`, Close is brown text `9C5700` on yellow fill `FFEB9C`. Update the item's existing rows too if your video raises it (e.g. Close → Exact) |
| G On Trending Social (Mentionlytics) | copy from the item's existing row, unchanged (blank if the item had no row) |
| H Direct Scraping (TikTok & YouTube) | the item's best scraped status, YouTube and TikTok together: `Exact` here for your rows. Set the same value on every row of the item, with the same styling as F |
| I Matched Content Item | the product name as the video writes it. Keep native script and add English in parentheses, e.g. `Trà Vải Cozy (Cozy Lychee Tea)` |
| J Channel | `TikTok` |
| K Profile | the creator's handle with the `@`, e.g. `@cozyvietnam`. Add ` (brand)` if it is the brand's own account |
| L Post Date | `YYYY-MM-DD` if TikTok shows a full date; `YYYY-MM` if it shows only a month; otherwise leave blank |
| M Views | leave blank (TikTok shows likes, not views) |
| N Likes | the like count as a **number**, format `#,##0`, right-aligned. If TikTok shows `3.7K`, open the video for the exact number. If only an abbreviation exists, convert it (`3.7K` → `3700`, `1.2M` → `1200000`) |
| O Approx. Count | `Yes`, centred, only when the Likes number came from an abbreviation; otherwise blank |
| P Engagement (as shown) | the count as TikTok shows it, with a unit: `3,706 likes`, or `~3.7K likes` for an abbreviation |
| Q Caption | the full caption text, hashtags included |
| R Link | the text `Open ↗`, hyperlinked to the video's own URL, `https://www.tiktok.com/@handle/video/<id>`, never a search or discover page. Blue `0563C1`, underlined |
| S Source | `Direct Scraping` |
| T Match Note | `Brand + product/flavor named in video.` plus any caveat, e.g. pack size differs or it is the powder version |

## When you are done

1. Delete the **TikTok Search List** sheet. The finished workbook has exactly two sheets,
   in this order: *Summary* (first) and *Promo vs Social Listening*.
2. On the **Summary** sheet, leave every formula alone; they recount automatically. Then:
   - In **Unmatched promo items (no post found)**, delete the rows of items you just
     matched, so the list keeps only items with no post at all. Keep the grey note under
     the list.
   - Check that the Total "Promo Items" (first table) still equals the number of promo
     items in the footnote. If it is higher, an item still has an `Unmatched` row next to
     a new `Exact` row; fix that row.
3. On *Promo vs Social Listening*, keep the header row, the freeze at D2, and the filter on
   the header row, extended to the last row.
4. Save as the same file name and give it back to me, with a short list of which items got
   TikTok rows and which you searched but found nothing exact for.
