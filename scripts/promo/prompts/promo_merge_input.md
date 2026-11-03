# Merge the month's promo files into the pipeline's INPUT file

Each month, attach the month's **two** source files to Claude and paste everything below
the line:

1. the promo list, `UST <YYYY> <MON> PROMO.xlsx` (e.g. `UST 2026 NOV PROMO.xlsx`);
2. the description file with photos, `UST <YYYY> <MON> NEW - desc.xlsx`
   (e.g. `UST 2026 NOV NEW - desc.xlsx`).

Claude returns one workbook, `UST <YYYY> <MON> PROMO INPUT.xlsx`, with the photos
floating over their cells. Then:

1. `python scripts/promo/photos_in_cells.py "<file>"` puts the photos inside their cells.
2. `python scripts/promo/validate_promo_input.py "<file>"` checks it.
3. Upload ONLY that file to the landing Volume.

The layout is defined in `scripts/promo/promo_input_schema.py`; this prompt states the same
rules in words. If the two ever disagree, the schema file wins.

---

You are merging a distributor's monthly promo files into ONE workbook with a fixed
layout, so a data pipeline can read it no matter how the source files were laid out this
month. Copy values; never invent, guess, translate or tidy them.

## The sources

Two files are attached:

- **The promo list**, `UST <YYYY> <MON> PROMO.xlsx`: the items on promotion this month.
  This is the **master list**: every one of its rows becomes exactly one row in the
  output, and nothing else does.
- **The description file**, `UST <YYYY> <MON> NEW - desc.xlsx`: extra detail for some
  of those items: a product photo, notes, selling points and a short description. It only
  **adds detail** to items already on the promo list.

If any other file is attached, or one of these two is missing, stop and tell me.

Column names differ month to month. Match them by meaning, e.g. `Item No.` = `No.`,
`Size` = `Base UOM Size`, `ETA` = `Expected Receive Date`.

**Which list (`promo_list`).** A promo-list sheet named `<MON> NEW` or `<MON> PROMO` says
which list its rows are on. When the sheet has a generic name (`Sheet1`), take the list
from the description file's sheet name: a description sheet named `NOV NEW` means the
promo list's rows are the `NEW` list. If neither file says, stop and ask me.

## The output workbook

File name: `UST <YYYY> <MON> PROMO INPUT.xlsx`, e.g. `UST 2026 NOV PROMO INPUT.xlsx`.

### Sheet `items`

Row 1 holds exactly these column names, in this order, lower case. Then one row per
promo-list row, in the order of the promo list (all of the NEW list first, then the
PROMO list, if both exist).

| Column | Required | What goes in it |
|---|---|---|
| `promo_month` | yes | The promo month as `YYYY-MM`, e.g. `2026-11`. The same on every row. |
| `promo_list` | yes | `NEW` or `PROMO`: which list the row is on. |
| `item_no` | yes | The item number, digits only, e.g. `35060`. |
| `description` | yes | The description exactly as on the promo list, cut-off text included. |
| `size` | yes | The case size as on the promo list, e.g. `12X17.64OZ`. |
| `promo_code` | no | The promo code, e.g. `5+1`. |
| `vendor_no` | no | The vendor number. |
| `starting_date` | no | The promo start date, `YYYY-MM-DD`. |
| `ending_date` | no | The promo end date, `YYYY-MM-DD`. |
| `eta` | no | Expected arrival, `YYYY-MM-DD`. |
| `buyer_code` | no | The buyer code. |
| `origin_code` | no | Country of origin, 2 letters, e.g. `VN`. |
| `brand` | no | The brand, ONLY when a source states it, e.g. a note "Comoja Sandwich Thin Biscuits are…" gives `Comoja`. Never guess it from the description or a photo. |
| `short_description` | no | The description file's short description, as written. |
| `selling_points` | no | The description file's selling points, in order, joined with ` \| `, e.g. `Peelable Fruit Skin \| Two Different Textures \| Fun Interactive Snack`. |
| `notes` | no | The description file's notes, as written. |
| `photo` | no | The item's photo from the description file, placed in this cell. |

Rules for the rows:
- **Join the description file to the promo list by item number.** Never by description:
  two rows can share a description (the same product in two case sizes, e.g. 35060 and
  35061 are both `HOSHI GUMMY MANGO`), and each keeps its own detail and photo.
- An item on the promo list but not in the description file keeps its promo-list
  columns and leaves the detail columns blank.
- An item on both the NEW and PROMO lists gets two rows, one per list. An item twice on
  the same list is an error in the sources: stop and tell me.
- Leave a cell **blank** when no source has the value. Never write `N/A`, `-`, `0` or
  `#VALUE!`. A cell that shows `#VALUE!` in the description file's Image column is the
  photo: copy the picture, not the text.
- Dates as `YYYY-MM-DD` text, even if the source shows them another way.
- Item numbers as plain digits: `35060`, not `35060.0`.
- **Photos**: copy each picture from the description file into the `photo` cell of the
  SAME item number, unchanged (no cropping, resizing for quality, or substitutes). Put it
  in the cell (Excel "Place in Cell") or anchor it on that cell. One photo per row; an
  item with no photo has an empty cell. Never take a photo from anywhere else.

**Reading the photos.** The description file's pictures are Excel "Place in Cell"
pictures. openpyxl does not see them (the cell reads `#VALUE!` and `ws._images` is
empty), so read them from the .xlsx zip itself:

1. In the sheet's XML (`xl/worksheets/sheetN.xml`), each Image cell with a picture has a
   `vm="n"` attribute, e.g. `<c r="G2" vm="1" ...>`. The row number is in `r`.
2. `xl/metadata.xml`: `<valueMetadata>` block `n` (1-based) holds `<rc v="k"/>`;
   `<futureMetadata>` block `k` (0-based) holds `<xlrd:rvb i="j"/>`.
3. `xl/richData/rdrichvalue.xml`: rich value `j` (0-based); its first `<v>` is index `m`.
4. `xl/richData/richValueRel.xml`: relationship `m` (0-based) gives an `r:id`;
   `xl/richData/_rels/richValueRel.xml.rels` maps that id to the file, e.g.
   `../media/image1.png` = `xl/media/image1.png`.

Copy those image bytes as they are. In the output, anchor each one on its `photo` cell
(openpyxl `ws.add_image(Image(BytesIO(data)), "Q<row>")`; set the display size so it fits
the row, which does not change the file). Count the pictures you found and the pictures you
wrote; they must agree, less only the photos of items on no promo list.

### Sheet `meta`

Two columns, `key` and `value`, one fact per row:

| key | value |
|---|---|
| `schema_version` | `1` |
| `promo_month` | the same `YYYY-MM` as the items sheet |
| `merged_on` | today's date, `YYYY-MM-DD` |
| `source` | one row per file you used: `<file name> (promo_list, <n> rows)` or `<file name> (detail, <n> rows)` |

### Sheet `unmatched_detail` (only when needed)

Description-file rows whose item number is on **no** promo list: copy them here with
their original columns. The pipeline does not load them; they are listed so a person can
ask whether the item was meant to be on promotion.

## Reply

Give me the workbook, then a short check:
1. rows per list (e.g. `NEW 92`), and how many have a description, selling points, a
   photo; and how many pictures the description file had (photos must not be lost);
2. promo-list items with no description-file row (item numbers and descriptions);
3. description-file items on no promo list (the `unmatched_detail` sheet);
4. any source values you could not place, and any column you matched by meaning
   (e.g. `Base UOM Size` → `size`).
