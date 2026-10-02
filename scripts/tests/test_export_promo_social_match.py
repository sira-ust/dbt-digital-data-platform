"""The workbook export: layout, formatting and live formulas, from synthetic rows.

No database needed — build_workbook() takes the same dict read_inputs() returns.
The formula test needs the optional `formulas` package (a spreadsheet engine) and
is skipped without it. Run:  python -m pytest scripts/tests
"""

import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest  # noqa: E402
from openpyxl import load_workbook  # noqa: E402

import export_promo_social_match as ex  # noqa: E402


def _row(sheet, row_order, item_no, desc, status, rank=1, **match):
    base = {"promo_sheet": sheet, "row_order": row_order, "match_rank": rank, "item_no": item_no,
            "item_no_int": int(item_no), "promo_description": desc + "  ", "promo_size": "24X10.9OZ",
            "promo_code": None if sheet.endswith("NEW") else "5+1", "match_status": status,
            "matched_content_item": None, "channel": None, "profile": None, "post_date": None,
            "engagement_text": None, "caption": None, "link": None, "source": None,
            "match_note": None}
    base.update(match)
    return base


def _item(sheet, row_order, item_no, desc, branded=True, **kw):
    base = {"promo_sheet": sheet, "row_order": row_order, "item_no": item_no, "promo_description": desc,
            "promo_size": "24X10.9OZ", "is_branded": branded, "brand": "Fanta" if branded else None,
            "product": "soft drink", "flavor_variant": "grape", "search_queries": "แฟนต้า องุ่น|fanta grape",
            "brand_terms": "fanta|แฟนต้า", "flavor_terms": "grape|องุ่น", "negative_terms": None,
            "source_file": "UST 2026 OCT NEW PROMO.xlsx"}
    base.update(kw)
    return base


@pytest.fixture
def data():
    sl = dict(matched_content_item="ดีโด้ น้ำส้มสายน้ำผึ้ง (Deedo Sainamphueng orange juice)",
              channel="Web", profile="trueid.net", post_date="2026-07-13", engagement_text="Not reported",
              caption="มิกซ์ กาแฟส้ม", link="https://www.trueid.net/watch/th-th/short/8yXZnXjx325b",
              source="Social Listening", match_note="Brand, product and flavor match.")
    yt = dict(matched_content_item="Fanta Grape", channel="YouTube", profile="Fanta TH", post_date="2022-03-14",
              engagement_text="176,000 views, 900 likes", caption="ระเบิดความซ่ากับองุ่นป๊อบ!",
              link="https://www.youtube.com/watch?v=GUwN8yYJboI", source="Scraped",
              match_note="Brand + product/flavor named in video.")
    rows = [
        _row("OCT NEW", 1, "86251", "BAMBOO SUSHI MAT", "Unmatched"),
        _row("OCT NEW", 2, "37353", "BENTO SQUID SNACK (BBQ CHEESE)", "Close",
             **{**sl, "matched_content_item": "Mực Bento", "match_note": "Same brand/product line"}),
        _row("OCT PROMO", 1, "34585", "DEEDO SAINAMPHUENG FRUIT JUICE", "Exact", **sl),
        _row("OCT PROMO", 2, "34662", "FANTA GRAPE FLAVOR", "Exact", 1, **yt),
        _row("OCT PROMO", 2, "34662", "FANTA GRAPE FLAVOR", "Exact", 2, **{**yt, "link": "https://youtu.be/x"}),
        _row("OCT PROMO", 3, "34658", "FANTA ORANGE FLAVOR", "Unmatched"),
    ]
    items = [_item("OCT NEW", 1, "86251", "BAMBOO SUSHI MAT", branded=False),
             _item("OCT NEW", 2, "37353", "BENTO SQUID SNACK (BBQ CHEESE)"),
             _item("OCT PROMO", 1, "34585", "DEEDO SAINAMPHUENG FRUIT JUICE"),
             _item("OCT PROMO", 2, "34662", "FANTA GRAPE FLAVOR"),
             _item("OCT PROMO", 3, "34658", "FANTA ORANGE FLAVOR", flavor_terms=None)]
    return {"promo_month": "2026-10-01", "rows": rows, "items": items,
            "mentions": {"n": 53601, "first_at": datetime(2026, 2, 20), "last_at": datetime(2026, 9, 29)},
            "searched_at": datetime(2026, 10, 2, 5, 0)}


@pytest.fixture
def saved(data, tmp_path):
    path = tmp_path / ex.output_name(data["promo_month"])
    ex.build_workbook(data).save(path)
    return path


def test_file_name(data):
    assert ex.output_name(data["promo_month"]) == "UST_OCT_Promo_Social_Listening_Match.xlsx"


def test_sheets_and_header(saved):
    wb = load_workbook(saved)
    assert wb.sheetnames == ["Promo vs Social Listening", "Summary", "TikTok Search List"]
    ws = wb["Promo vs Social Listening"]
    assert [c.value for c in ws[1]] == [
        "Promo Sheet", "Item No.", "OCT Promo Item", "Size", "Promo Code", "Match Status",
        "Matched Content Item", "Channel", "Profile", "Post Date", "Views / Engagement",
        "Caption", "Link", "Source", "Match Note"]
    h = ws["A1"]
    assert h.font.bold and h.font.name == "Arial" and h.font.color.rgb.endswith("FFFFFF")
    assert h.fill.fgColor.rgb.endswith("1F4E78") and h.alignment.horizontal == "center" and h.alignment.wrap_text


def test_layout(saved):
    ws = load_workbook(saved)["Promo vs Social Listening"]
    widths = [ws.column_dimensions[c].width for c in "ABCDEFGHIJKLMNO"]
    assert widths == [12, 10, 34, 16, 11, 13, 40, 11, 20, 12, 22, 60, 45, 16, 40]
    assert ws.freeze_panes == "D2"
    assert ws.auto_filter.ref == f"A1:O{ws.max_row}"


def test_rows_order_types_and_formatting(saved):
    ws = load_workbook(saved)["Promo vs Social Listening"]
    rows = list(ws.iter_rows(min_row=2, values_only=True))
    assert [r[0] for r in rows] == ["OCT NEW"] * 2 + ["OCT PROMO"] * 4      # NEW first, source order
    assert all(isinstance(r[1], int) for r in rows)                        # Item No. is an integer
    assert rows[0][2] == "BAMBOO SUSHI MAT"                                 # trimmed
    assert rows[0][4] is None                                               # blank promo code
    assert all(v is None for v in rows[0][6:])                              # Unmatched: blanks
    assert rows[3][1] == rows[4][1] == 34662                                # consecutive rows per item
    body = ws["C2"]
    assert body.font.name == "Arial" and body.font.size == 10
    assert body.alignment.vertical == "top" and body.alignment.wrap_text
    assert body.border.left.color.rgb.endswith("BFBFBF")


def test_status_fills_and_links(saved):
    ws = load_workbook(saved)["Promo vs Social Listening"]
    fills = {ws[f"F{r}"].value: ws[f"F{r}"].fill.fgColor.rgb[-6:] for r in range(2, ws.max_row + 1)}
    assert fills == {"Unmatched": "F2F2F2", "Close": "FFEB9C", "Exact": "C6EFCE"}
    assert all(ws[f"F{r}"].font.bold for r in range(2, ws.max_row + 1))
    link = ws["M4"]
    assert link.hyperlink.target == link.value and link.value.startswith("https://")
    assert link.font.underline == "single" and link.font.color.rgb.endswith("0563C1")


def test_summary_formulas_and_footnote(saved):
    sm = load_workbook(saved)["Summary"]
    assert [c.value for c in sm[1]] == ["Match Status", "Promo Items", "Matched Posts (rows)"]
    assert [sm[f"A{r}"].value for r in range(2, 6)] == ["Exact", "Close", "Unmatched", "Total"]
    assert sm["B2"].value.startswith("=SUMPRODUCT(") and "COUNTIFS(" in sm["B2"].value
    assert sm["C2"].value == "=IF(A2=\"Unmatched\",0,COUNTIF('Promo vs Social Listening'!F:F,A2))"
    assert sm["B5"].value == "=SUM(B2:B4)" and sm["C5"].value == "=SUM(C2:C4)"
    note = sm["A7"].value
    assert "UST 2026 OCT NEW PROMO.xlsx (5 items)" in note and "53,601 posts" in note
    assert "Oct 2, 2026" in note and "YouTube shows views; TikTok shows likes" in note


def test_tiktok_list_has_unmatched_branded_items_only(saved):
    tk = load_workbook(saved)["TikTok Search List"]
    items = [r[0] for r in tk.iter_rows(min_row=2, values_only=True)]
    # unbranded sushi mat: no; Bento + Deedo matched in social listening: no;
    # Fanta Grape (YouTube Exact) and Fanta Orange (Unmatched): yes
    assert items == [34662, 34658]
    assert tk["G2"].value == "Exact (YouTube)" and tk["G3"].value == "Unmatched"
    assert tk["J3"].value == "(no flavor to require)"
    assert tk["L2"].hyperlink.target.startswith("https://www.tiktok.com/search/video?q=")


def test_summary_formulas_recalculate(saved):
    formulas = pytest.importorskip("formulas")
    model = formulas.ExcelModel().loads(str(saved)).finish()
    sol = model.calculate()

    def val(ref):
        key = next(k for k in sol if k.upper().endswith(f"SUMMARY'!{ref}"))
        v = sol[key].value
        return float(v[0][0] if hasattr(v, "__getitem__") else v)

    # Exact: Deedo + Fanta Grape = 2 items, 3 rows; Close: Bento 1/1; Unmatched: 2 items, 0 rows
    assert [val(f"B{r}") for r in (2, 3, 4, 5)] == [2, 1, 2, 5]
    assert [val(f"C{r}") for r in (2, 3, 4, 5)] == [3, 1, 0, 4]
