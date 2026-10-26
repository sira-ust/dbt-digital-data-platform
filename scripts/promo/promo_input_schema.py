"""The monthly promo INPUT file: one workbook in a fixed layout, whatever the
source files looked like that month.

UST sends the promo list and, since NOV 2026, a description file with photos,
selling points and short descriptions. Their columns and sheet names change month
to month ("Item No." vs "No.", "Size" vs "Base UOM Size", "NOV NEW" vs "Sheet1").
So each month the source files are merged, by Claude with
scripts/promo/prompts/promo_merge_input.md, into ONE workbook in the layout below, and
the pipeline reads only that layout. validate_promo_input.py checks a file against
it before the run; load_promo_list.py loads it.

    UST <YYYY> <MON> PROMO INPUT.xlsx
      items   one row per promo-list row (the columns below), in list order
      meta    key | value: schema_version, promo_month, merged_on, and one
              "source" row per file used
      unmatched_detail   (optional) description-file rows whose item is on no
              promo list: kept for a person to look at, never loaded

THIS FILE IS THE CONTRACT. KEEP IN STEP with scripts/promo/prompts/promo_merge_input.md
(a test checks that the prompt names every column) and with the docs in
models/docs/_promo_social.md.
"""

from __future__ import annotations

from dataclasses import dataclass

SCHEMA_VERSION = "1"
SHEET_ITEMS, SHEET_META, SHEET_UNMATCHED = "items", "meta", "unmatched_detail"
PROMO_LISTS = ("NEW", "PROMO")            # the list an item is on: "<MON> NEW" / "<MON> PROMO"


@dataclass(frozen=True)
class Column:
    name: str
    required: bool          # a blank value is an error
    kind: str               # text | item_no | month | list | date | code | pipe_list | photo
    source: str             # promo_list | detail | merge: where the value comes from
    meaning: str


COLUMNS = [
    # ── which list, which row ────────────────────────────────────────────────
    Column("promo_month", True, "month", "merge",
           "The promo month as YYYY-MM, e.g. 2026-11. The same on every row."),
    Column("promo_list", True, "list", "promo_list",
           "NEW or PROMO: the list the row is on (sheet '<MON> NEW' or '<MON> PROMO')."),
    Column("item_no", True, "item_no", "promo_list",
           "The NAV item number, digits only, e.g. 35060 ('Item No.' or 'No.' in the sources)."),
    # ── from the promo list, as written ─────────────────────────────────────
    Column("description", True, "text", "promo_list",
           "The NAV description exactly as on the promo list, truncation included."),
    Column("size", True, "text", "promo_list",
           "The case size as on the promo list, e.g. 12X17.64OZ ('Size' or 'Base UOM Size')."),
    Column("promo_code", False, "text", "promo_list", "The promo code, e.g. 5+1. Blank when none."),
    Column("vendor_no", False, "text", "promo_list", "The vendor number. Blank when not given."),
    Column("starting_date", False, "date", "promo_list", "The promo start date, YYYY-MM-DD."),
    Column("ending_date", False, "date", "promo_list", "The promo end date, YYYY-MM-DD."),
    Column("eta", False, "date", "promo_list", "Expected arrival ('ETA' or 'Expected Receive Date'), YYYY-MM-DD."),
    Column("buyer_code", False, "text", "promo_list", "The buyer code."),
    Column("origin_code", False, "code", "promo_list",
           "Country of origin, 2 letters, e.g. VN, TH ('Origin Code')."),
    # ── from the description file, when it has the item ─────────────────────
    Column("brand", False, "text", "detail",
           "The brand, ONLY when a source states it (e.g. a note says 'Comoja Sandwich Thin "
           "Biscuits'). Never guessed from the description."),
    Column("short_description", False, "text", "detail", "The description file's 'Short Description'."),
    Column("selling_points", False, "pipe_list", "detail",
           "The selling points joined with ' | ', in order, e.g. 'Peelable Fruit Skin | Two Different Textures'."),
    Column("notes", False, "text", "detail", "The description file's 'Notes', as written."),
    Column("photo", False, "photo", "detail",
           "The product photo, as a picture placed in this cell (Excel 'Place in Cell') or a "
           "picture anchored on it. Copied from the description file, never from the web."),
]

COLUMN_NAMES = [c.name for c in COLUMNS]
REQUIRED = [c.name for c in COLUMNS if c.required]
META_REQUIRED = ("schema_version", "promo_month", "merged_on", "source")
