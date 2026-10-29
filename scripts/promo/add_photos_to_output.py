"""Add the product photos to a finished output workbook, from the month's INPUT file.

The export puts each item's photo beside its name (the Photo column) since
2026-10-28. A workbook exported before that has none; this adds them, matched by
ITEM NUMBER (never by description: 35060 and 35061 are both HOSHI GUMMY MANGO, each
with its own photo):

    python scripts/promo/add_photos_to_output.py "UST_NOV_Promo_Social_Listening_Match.xlsx" "UST 2026 NOV PROMO INPUT.xlsx"

- The workbook has a Photo column: the photos go in it.
- It has none: a Photo column is added AFTER the last column, so no formula, link or
  note on the sheet moves, and the header filter is widened to take it in (a sort from
  the filter arrows otherwise moves the items and leaves the photos behind).
- Every item row gets the same height, so a sorted photo never lands on a short row.

Photos float INSIDE their cells, set to "move and size with cells": Excel carries them
along when the sheet is sorted, and openpyxl keeps them when it saves, so a later edit by
Claude does not drop them. (Once the file is final, scripts/promo/photos_in_cells.py
places them in the cells for good.) An item that already has a photo on its cell is left
as it is: safe to run twice. The file is rewritten in place unless --out is given.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path.cwd() / "scripts" / "promo"))
try:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
except NameError:
    pass

from promo_common import place_image_in_cell  # noqa: E402
from validate_promo_input import read_input  # noqa: E402

SHEET_MAIN = "Promo vs Social Listening"      # export_promo_social_match.SHEET_MAIN
PHOTO_ROW_HEIGHT, PHOTO_COL_WIDTH = 60, 14    # points / characters
PHOTO_BOX_PX = (100, 80)                      # pixels: that cell


def photos_by_item(input_path: str) -> dict[str, bytes]:
    """{item_no: photo bytes} from an INPUT file (in-cell or floating photos)."""
    data = read_input(input_path)
    row_item = {r["_row"]: str(r["item_no"]) for r in data["rows"] if r.get("item_no")}
    return {row_item[row]: blob for row, (blob, _) in data["photos"].items() if row in row_item}


def widen_filter(ws, col: int) -> None:
    """Take column `col` into the sheet's header filter. A sort from the filter arrows
    reorders only the filter's columns: a Photo column left outside keeps its photos
    where they were while the items move (NOV 2026: Lay's Spicy Lobster showed the
    glass-noodle photo after a sort by Match Status). openpyxl writes the filter's
    hidden _FilterDatabase name from this ref, so both stay in step."""
    from openpyxl.utils import get_column_letter
    from openpyxl.utils.cell import range_boundaries
    if not ws.auto_filter.ref:
        return
    min_col, min_row, max_col, max_row = range_boundaries(ws.auto_filter.ref)
    if max_col < col:
        ws.auto_filter.ref = f"{get_column_letter(min_col)}{min_row}:{get_column_letter(col)}{max_row}"


def add_photos(result_path: str, input_path: str, out: str | None = None) -> tuple[int, str]:
    """-> (photos added, the Photo column's letter)."""
    import openpyxl
    from copy import copy
    from openpyxl.utils import get_column_letter

    photos = photos_by_item(input_path)
    wb = openpyxl.load_workbook(result_path)
    if SHEET_MAIN not in wb.sheetnames:
        raise SystemExit(f"{os.path.basename(result_path)}: no sheet '{SHEET_MAIN}'")
    ws = wb[SHEET_MAIN]
    header = [str(c.value or "").strip() for c in ws[1]]
    if "Item No." not in header:
        raise SystemExit(f"{os.path.basename(result_path)}: no 'Item No.' column on {SHEET_MAIN}")
    item_col = header.index("Item No.") + 1
    if "Photo" in header:
        col = header.index("Photo") + 1
    else:                                    # after the last column: nothing on the sheet moves
        col = ws.max_column + 1
        cell, left = ws.cell(row=1, column=col, value="Photo"), ws.cell(row=1, column=col - 1)
        cell.font, cell.fill, cell.border, cell.alignment = (copy(left.font), copy(left.fill),
                                                              copy(left.border), copy(left.alignment))
        ws.column_dimensions[get_column_letter(col)].width = PHOTO_COL_WIDTH
    letter = get_column_letter(col)
    widen_filter(ws, col)
    taken = {(i.anchor._from.col, i.anchor._from.row) for i in ws._images}
    added = 0
    for r in range(2, ws.max_row + 1):
        item = ws.cell(row=r, column=item_col).value
        blob = photos.get(str(item).strip().removesuffix(".0")) if item is not None else None
        if not blob or (col - 1, r - 1) in taken:
            continue
        # inside its cell, "move and size with cells": a sort carries it along
        if place_image_in_cell(ws, blob, col, r, *PHOTO_BOX_PX):
            added += 1
    if added:
        # every item row the same height: a sort moves photos between rows, and a
        # photo sorted onto a shorter row would shrink
        for r in range(2, ws.max_row + 1):
            ws.row_dimensions[r].height = max(ws.row_dimensions[r].height or 0, PHOTO_ROW_HEIGHT)
    with tempfile.TemporaryDirectory() as tmp:
        tmp_out = Path(tmp) / "out.xlsx"
        wb.save(tmp_out)
        shutil.copyfile(tmp_out, out or result_path)
    return added, letter


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("result", help="the output workbook (UST_<MON>_Promo_Social_Listening_Match.xlsx)")
    ap.add_argument("input", help="the month's INPUT file, with the photos")
    ap.add_argument("--out", help="write here instead of rewriting the result in place")
    args = ap.parse_args(argv)
    n, letter = add_photos(args.result, args.input, args.out)
    print(f"{os.path.basename(args.out or args.result)}: {n} photo(s) added in column {letter}")


if __name__ == "__main__":
    main()
