# TikTok + RedNote search — monthly promo social match

Paste everything below the line into Claude in Chrome, and attach the month's
`UST_<MON>_Promo_Social_Listening_Match.xlsx` (the file the pipeline wrote). In that Chrome
window, stay signed in to **TikTok** and to **RedNote** on **rednote.com** (Xiaohongshu,
小红书; we can't open xiaohongshu.com). RedNote search shows nothing to a signed-out
visitor.

One prompt does both: TikTok searches English, Thai and Vietnamese, RedNote searches
Chinese (the only place the pipeline searches in Chinese). The rules are the ones the
pipeline applies to social listening posts and YouTube videos, so every source in the
workbook means the same thing by "Exact".

**Long lists.** Claude deletes each search-list row as soon as that item is done. If it
stops before the end, attach the file it gave back with this same prompt: it carries on
from the first row left.

**RedNote links.** A RedNote link only opens its note with the key in its address
(`xsec_token`), and the browser hides that key from Claude. So when the RedNote list is
done, Claude shows a box in the rednote tab listing the notes it kept: click **Copy links**
and paste them into the chat (or **Download CSV** and attach the file), and Claude puts the
links in the workbook. That is the only step it needs you for. The links stay saved in that
browser: if you were away, attach the file it gave back with this prompt and it shows the
box again.

---

You are adding TikTok videos and RedNote posts to a promo social-listening workbook.
Work through the attached workbook and give me the updated file back.

The workbook has two search lists, one row per promo item to search:
- **TikTok Search List**: search its phrases on **TikTok**. The phrases are English, Thai
  and Vietnamese.
- **RedNote Search List**: search its phrases on **RedNote** at **rednote.com**. Every
  phrase is Chinese. Never use xiaohongshu.com: it doesn't open for me. The row's **RedNote
  Search Link** points there, so open the same address with `www.rednote.com` in place of
  `www.xiaohongshu.com`.

Do the TikTok list first, then the RedNote list. **When you have finished an item on a
list, delete its row from that list**, so the rows left are always the work left. If you
cannot finish everything in one go, stop after a finished item, give me the file, and say
which list and item come next.

## What counts as a match (both platforms)

For each row:

1. Search **each line of Search Phrases** (the row's **Search Link** opens the first
   one). Each line starts with its language in brackets, e.g. `[Thai] แฟนต้า องุ่น`:
   search only the text after the brackets, and remember the language: it decides where
   the result goes on the main sheet. Look at the top results for each search, scrolling
   once or twice.
2. Keep a post only if it is an **exact match**. Its caption, title, on-screen text or
   hashtags (on RedNote also the text written on the note's pictures) must name
   - the **brand**: one of the *Must Mention (brand)* words, in any spelling: Latin
     letters, Thai, Vietnamese, Simplified or Traditional Chinese, or a hashtag. Chinese
     posts often write the brand in Latin letters ("Cozy 荔枝茶"); that counts. Never
     accept a brand name that is not on the list because it seems likely; and
   - the **product**: what the item is, e.g. tea, juice, energy drink, rice paper; and
   - the **flavor / variant**: one of the *Flavor Words*. Skip this check when the column
     says "(no flavor to require)".
3. Throw a post out when any of these apply:
   - it names a different flavor or edition of the brand, or says "new flavor" (新口味)
     without naming it;
   - the brand word means something else: a person, K-pop idol, film, restaurant, or an
     ordinary word like "cozy";
   - any phrase in **Exclude If** appears;
   - the brand appears only as one hashtag among many, with no product talk;
   - it is a shop listing or an ad with no post around it (a store product listing, or a
     sponsored placement that is only a price);
   - the pack shown is a **lookalike**: compare it with the row's **Photo** and **Product
     Card** (the flavor and text printed on the pack, the pack, the market it is sold in,
     and the lookalikes listed there). Another country's edition, another product line or
     another flavor's pack is out, even with the same brand and a similar name.

   A recipe or drink mix still counts when it names this exact item, e.g. "Red Bull mixed
   with Deedo Cantaloupe". A different pack size of the same product counts: say so in the
   cell note.
4. Prefer posts **from the past 2 years** (counted back from the start of the promo
   month, e.g. on or after 2024-11-01 for a NOV 2026 workbook). If the date isn't shown,
   open the post. RedNote often shows a relative date ("3天前", "昨天") or only month and
   day ("10-12" means this year): turn it into a date. If a language has **no** exact post
   from the past 2 years, take its best older ones instead and mark them `older` (below).
   Decide this per language, not per item.
5. **Per language**, take the **top 3 by performance** from the posts you kept: most likes
   (RedNote: 赞) first; for a tie, more comments (RedNote: more collects, 收藏). Fewer is
   fine. Never pad with weaker matches. Keep every language's results: a strong English
   video must never push out a Thai or Vietnamese one. A post that two phrases both found
   counts once, under the first phrase that found it.

### UST's own brands

Item descriptions use codes. **HB** = Honeybee, **DF** = Dragonfly, **D FZ** = Dragonfly
frozen, **CG** = Chung Guang: these are UST's own brands. **FZ** or **FROZEN** (frozen) and
**DFZ** (discontinued frozen) are not brands, so "FZ DF SESAME DONUT" is a frozen
Dragonfly item. Own-brand items are always on the search lists, even when trending social
(Mentionlytics) already found posts for them: their **Current Status** then says so, e.g.
`Close (On Trending Social)`. Search them like any other brand:
- **Honeybee**: on TikTok also search the Thai spelling ฮันนี่บี.
- **Dragonfly**: in Vietnam it is sold as **Chuồn Chuồn**, so on TikTok search that name
  too. A post counts when it names either Dragonfly or Chuồn Chuồn together with the
  product. "Chuồn chuồn" on its own also means the insect, so it is not enough.

### Frozen items with no brand

A row whose **Must Mention (brand)** starts with `(no brand: frozen product)` is a frozen
item with no brand (e.g. "FZ PURE SUGARCANE JUICE"). Search its phrases the same way, but
keep a post only when:
- it names the **product** and, when the item has one, the **flavor / variant**; and
- it shows a **frozen, packaged** product (速冻, 冷冻): a frozen pack being bought,
  unboxed, heated or reviewed, whatever its brand.

Throw out homemade recipes, street-food stalls, restaurant dishes and fresh (not frozen)
versions, even when the dish is the same. These posts can't confirm a brand, so they are
**`Close`**, never `Exact`: give their cells the yellow Close fill, and start their cell
note with `No brand to match (frozen item); frozen packaged product named in post.`

## Where each result goes on "Promo vs Social Listening"

That sheet has **one row per item**: find it by its **Item No.** column. Never add rows.
Find every column by its **header in row 1**, never by its letter: the layout can differ
from month to month. A **Photo** column, when there is one, holds the item's product photo
as a picture over the cell, the same photo as on the search lists. Leave it, and every
other picture, exactly where it is.

After the item's columns (the last one is **Posts**) come the **result blocks**, three
cells each:
*Trending Social 1–3*, then one block per search language: *English 1–3*, *Thai 1–3*,
*Vietnamese 1–3*, *Chinese 1–3*.

- **TikTok** results go in the block of **the language of the phrase that found them**
  (English, Thai or Vietnamese), in the first empty cell. **Never write a TikTok result in
  the Chinese block.**
- **RedNote** results go **only in the Chinese block**. Never write a RedNote result in
  another block.
- A cell holding `–` means the item was not searched in that language; you may overwrite
  it if you did search that language.
- **A full block.** If the three cells already hold results (e.g. YouTube videos the
  pipeline found), compare likes: a YouTube cell shows them as `… · 900 likes · …`. Your
  post replaces the result with the fewest likes only if yours has more; a cell without a
  likes figure counts as 0. Otherwise leave the block as it is. Never move a result into
  another language's block to make room.

**Each result cell:**
- **Text**: `<Platform> · <likes> likes · <post date>`, e.g.
  `TikTok · 3,706 likes · 2025-02-14` or `RedNote · 1,204 likes · 2025-08-19`. The text
  must start with `TikTok · ` or `RedNote · `: the Summary counts results by it.
  - Likes as the platform shows them. If TikTok shows only an abbreviation, open the
    video for the exact number; if there is none, use a tilde: `~3.7K likes`. RedNote
    writes large numbers in 万 (1.2万 = 12,000): write those as `~12,000 likes`.
  - Post date as `YYYY-MM-DD` (TikTok: `YYYY-MM` if it shows only a month); leave it out
    if unknown. Add ` · older` at the end for a post older than 2 years (step 4).
- **Link**: the cell hyperlinks to the post's own URL, never a search page:
  - TikTok: `https://www.tiktok.com/@handle/video/<id>`;
  - RedNote: `https://www.rednote.com/discovery/item/<note id>?xsec_token=…`, never
    xiaohongshu.com. The note ID is the 24 letters and digits after `/item/`, `/explore/`
    or `/search_result/` in the note's address. Without its `xsec_token` key the link
    opens a 404, and the browser hides the key from you. So link the cell to the plain
    `https://www.rednote.com/discovery/item/<note id>` for now: **RedNote links** (below)
    saves the full link as you go and puts it in at the end.

  Blue text `0563C1`, underlined, Arial 10.
- **Fill**: green `C6EFCE` for an Exact post, yellow `FFEB9C` for a Close one (frozen items
  with no brand).
- **Note** (a cell comment), four parts separated by blank lines:
  1. the product name as the post writes it, native script kept with English in
     parentheses, e.g. `Trà Vải Cozy (Cozy Lychee Tea)`, `芬达葡萄味 (Fanta Grape)`;
  2. the creator's handle or name (TikTok with the `@`), plus ` (brand)` if it is the
     brand's own account;
  3. the full caption, hashtags included (RedNote: title and text, with an English
     translation after the original);
  4. `Brand + product/flavor named in post.` plus any caveat, e.g. pack size differs, the
     powder version, or the brand is named only in the picture text. For an older post,
     start this part with `Older than 2 years: no recent post was found.`

**Then update the item's columns:**

| Column | Value |
|---|---|
| Match Status | the item's best status across everything on its row: `Exact` if any result is Exact, else `Close`. Bold; Exact is dark green text `006100` on green fill `C6EFCE`, Close is brown text `9C5700` on yellow fill `FFEB9C`. An item that was Unmatched stops being grey: use black text in its other item columns and in Posts |
| On Trending Social (Mentionlytics) | unchanged |
| Direct Scraping (TikTok, YouTube & RedNote) | the best scraped status, YouTube, TikTok and RedNote together, styled like Match Status |
| Posts | a formula: leave it alone, it recounts by itself |

## RedNote links

The browser hides the `xsec_token` key in a RedNote address from you, so the full links
reach the workbook through me. Don't look for other ways to read the keys. Run the two
snippets below in the rednote tab with your JavaScript tool. When the file comes back with
no search lists left, do only steps 2 to 4, for the cells still waiting.

**1. Save each kept post's link.** Whenever you keep a RedNote post, run this while its
card shows on the search page, or with the note open, after changing `NOTE_ID` to its note
ID. It saves the full link in this browser's storage for rednote.com, where it stays
through page changes and later runs, and answers only `saved` and a count. If it answers
`not found`, scroll until the card shows (or open the note) and run it again.

```js
// Save a kept RedNote post's full link in this browser. Change NOTE_ID.
((id) => {
  const store = 'ust_rednote_links';
  const hasKey = (u) => /[?&]xsec_token=[^&]+/.test(u);
  let link = location.href.includes(id) && hasKey(location.href) ? location.href : '';
  if (!link) {
    const a = [...document.querySelectorAll(`a[href*="${id}"]`)].find((x) => hasKey(x.href));
    if (a) link = a.href;
  }
  if (!link) return `not found: show the card of ${id} (or open the note), then run this again`;
  const u = new URL(link);
  u.hostname = 'www.rednote.com';
  u.pathname = `/discovery/item/${id}`;
  if (!u.searchParams.get('xsec_source')) u.searchParams.set('xsec_source', 'pc_search');
  try {
    const saved = JSON.parse(localStorage.getItem(store) || '{}');
    saved[id] = u.href;
    localStorage.setItem(store, JSON.stringify(saved));
    return `saved ${id} (${Object.keys(saved).length} links saved)`;
  } catch (e) {
    return 'not saved: this page blocks browser storage';
  }
})('NOTE_ID');
```

**2. When the RedNote list is done, show the links box.** Change the list at the end of
this snippet to every RedNote cell in the Chinese block whose link has no `xsec_token`,
from this run and earlier ones: one line per note ID, with its item numbers and cells, e.g.
`['693a3792000000001e004acc', '73094 V83, 73096 V84']`. A box opens at the top right of
the rednote tab with a line per note and the buttons **Copy links** and **Download CSV**;
it never shows the links. The snippet answers how many notes are saved and lists any
`missing` one: search that note's phrase again until its card shows, save it with
snippet 1, and run this again.

```js
// Show the RedNote links box. One line per note: [note ID, item numbers and cells].
((notes) => {
  const store = 'ust_rednote_links';
  let saved = {};
  try { saved = JSON.parse(localStorage.getItem(store) || '{}'); } catch (e) {}
  const isSaved = ([id]) => /[?&]xsec_token=[^&]+/.test(saved[id] || '');
  const ready = notes.filter(isSaved);
  const csv = () => ['note_id,url', ...ready.map(([id]) => `"${id}","${saved[id]}"`)].join('\n');
  const add = (tag, text, css) => {
    const el = document.createElement(tag);
    el.textContent = text;
    el.style.cssText = css || '';
    return el;
  };
  document.getElementById('ust-rednote-box')?.remove();
  const box = add('div', '', 'position:fixed;top:16px;right:16px;z-index:2147483647;width:320px;max-height:80vh;overflow:auto;background:#fff;color:#111;border:2px solid #0563c1;border-radius:10px;padding:14px;font:14px/1.5 system-ui,sans-serif;box-shadow:0 8px 24px rgba(0,0,0,.25)');
  box.id = 'ust-rednote-box';
  box.append(
    add('div', 'RedNote links for the workbook', 'font-weight:700'),
    add('div', `${ready.length} of ${notes.length} saved. Click Copy links, then paste them into the Claude chat.`, 'margin:4px 0 8px'),
    ...notes.map((n) => add('div', `${isSaved(n) ? '✓' : '✗ missing:'} ${n[1]}`)),
  );
  const bar = add('div', '', 'display:flex;flex-wrap:wrap;gap:8px;margin-top:12px');
  const button = (label, onClick) => {
    const b = add('button', label, 'padding:6px 10px;border:1px solid #999;border-radius:6px;background:#f4f4f6;color:#111;font:inherit;cursor:pointer');
    b.addEventListener('click', (e) => { e.stopPropagation(); onClick(b); });
    bar.append(b);
  };
  button('Copy links', async (b) => {
    let ok = true;
    try {
      await navigator.clipboard.writeText(csv());
    } catch (e) {
      const t = add('textarea', '', 'position:fixed;left:-9999px');
      t.value = csv();
      document.body.append(t);
      t.select();
      ok = document.execCommand('copy');
      t.remove();
    }
    b.textContent = ok ? 'Copied ✓' : 'Copy failed: use Download CSV';
  });
  button('Download CSV', () => {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([csv()], { type: 'text/csv' }));
    a.download = 'rednote_links.csv';
    document.body.append(a);
    a.click();
    a.remove();
  });
  button('Close', () => box.remove());
  box.append(bar);
  document.body.append(box);
  const missing = notes.filter((n) => !isSaved(n)).map((n) => `${n[0]} (${n[1]})`);
  return `box shown: ${ready.length} of ${notes.length} saved` + (missing.length ? `; missing: ${missing.join(', ')}` : '');
})([
  ['NOTE_ID', 'ITEM NO. CELL'],
]);
```

**3. Hand-off.** Ask me to click **Copy links** in the box and paste into the chat, or to
click **Download CSV** and attach the file. Either way you get two columns, `note_id` and
`url`.

**4. Put the links in.** Give every RedNote cell with that note ID its pasted link, and
keep the cell's text, fill and note. Then open three of the links (all, if fewer) to check
that each shows its note, not a 404 or a search page. If one opens a 404, save that note
again with snippet 1 and repeat steps 2 to 4 for it.

If you stop before the RedNote list is done, skip steps 2 to 4: the plain links stay, and
the run that finishes the list does them all. If I don't answer, save the file with the
plain links and tell me which cells are still waiting.

## When you are done

1. Finish **RedNote links** (above), so every RedNote cell opens its note.
2. Both search lists are now empty: delete the **TikTok Search List** and **RedNote Search
   List** sheets. The finished workbook has exactly two sheets, in this order: *Summary*
   (first) and *Promo vs Social Listening*.
3. On the **Summary** sheet, leave every formula alone; they recount automatically. Then
   in **Unmatched promo items (no post found)**, delete the rows of items you matched, so
   the list keeps only items with no post at all. Keep the grey note under the list.
4. On *Promo vs Social Listening*, keep the header row, the frozen panes as they are, the
   filter on the header row and the photos. The sheet still has exactly one row per promo
   item.
5. Save as the same file name and give it back to me, with a list of every item you
   searched: for each, which phrases you searched on which platform (by language) and how
   many exact posts you kept per language, including the ones where you found none. If any
   RedNote cell still has a plain link, say which.
