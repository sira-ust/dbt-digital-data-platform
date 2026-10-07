"""Write UST_<MON>_Promo_Social_Listening_Match.xlsx from mart_promo_social_match (step 5).

Three sheets:
  1. "Promo vs Social Listening"  one row per matched post / video, or one Unmatched
                                  row per item — the exact October layout (columns,
                                  widths, fills, fonts, freeze D2, autofilter).
  2. "Summary"                    per-status counts as LIVE formulas over sheet 1, so
                                  rows added afterwards (TikTok) are counted without
                                  re-running anything.
  3. "TikTok Search List"         the items to search on TikTok by hand with Claude in
                                  Chrome (prompt: scripts/prompts/tiktok_promo_search.md):
                                  every branded item social listening did not match,
                                  with search phrases, required words, exclusions and
                                  a TikTok search link. The prompt has Claude delete
                                  this sheet when done, leaving the 2-sheet deliverable.

Unlike the October workbook, "Promo Items" on the Summary is a formula too (a
distinct count of Item No. per status). October typed numbers in, which go stale
the moment a TikTok row turns an Unmatched item into Exact.

    python scripts/export_promo_social_match.py                       # latest month, local
    python scripts/export_promo_social_match.py --promo-month 2026-10-01 --out-dir C:/somewhere
    python scripts/export_promo_social_match.py --backend databricks  # -> the promo_output Volume
"""

from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
import urllib.parse
from datetime import date, datetime
from pathlib import Path

sys.path.insert(0, str(Path.cwd() / "scripts"))
try:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
except NameError:
    pass

from promo_common import (  # noqa: E402
    INTERMEDIATE_SCHEMA, REPORTING_SCHEMA, STAGING_SCHEMA, local_data_root, query,
    split_terms,
)

DBX_OUT_DIR = "/Volumes/ust_databricks/social/promo_output"
SHEET_MAIN, SHEET_SUMMARY, SHEET_TIKTOK = "Promo vs Social Listening", "Summary", "TikTok Search List"

HEADERS = ["Promo Sheet", "Item No.", "{MON} Promo Item", "Size", "Promo Code", "Match Status",
           "Matched Content Item", "Channel", "Profile", "Post Date", "Views / Engagement",
           "Caption", "Link", "Source", "Match Note"]
WIDTHS = [12, 10, 34, 16, 11, 13, 40, 11, 20, 12, 22, 60, 45, 16, 40]
STATUS_FILL = {"Exact": "C6EFCE", "Close": "FFEB9C", "Unmatched": "F2F2F2"}
HEADER_FILL, BORDER_COLOR, LINK_COLOR = "1F4E78", "BFBFBF", "0563C1"
FORMULA_ROWS = 5000          # Summary formulas cover this many sheet-1 rows

TIKTOK_HEADERS = ["Item No.", "{MON} Promo Item", "Size", "Brand", "Product", "Flavor / Variant",
                  "Current Status", "Search Phrases", "Must Mention (brand)", "Flavor Words",
                  "Exclude If", "TikTok Search Link"]
TIKTOK_WIDTHS = [10, 34, 16, 14, 22, 22, 14, 40, 36, 36, 30, 45]


# ─────────────────────────────────────────────────────────────────────────────
# Read
# ─────────────────────────────────────────────────────────────────────────────

def _rel(backend, dbx_schema, local_schema, name):
    return f"{dbx_schema}.{name}" if backend == "databricks" else f"{local_schema}.{name}"


def read_inputs(backend: str, promo_month: str | None) -> dict:
    mart = _rel(backend, REPORTING_SCHEMA, "ust_reporting", "mart_promo_social_match")
    items_rel = _rel(backend, INTERMEDIATE_SCHEMA, "ust_intermediate", "int_promo_items_enriched")
    if not promo_month:
        promo_month = str(query(backend, f"select max(promo_month) as m from {mart}")[0]["m"])[:10]
    rows = query(backend, f"""
        select * from {mart}
        where promo_month = date '{promo_month}'
        order by sheet_order, row_order, match_rank
    """)
    if not rows:
        raise SystemExit(f"no rows in {mart} for {promo_month}")
    items = query(backend, f"""
        select * from {items_rel}
        where promo_month = date '{promo_month}'
        order by sheet_order, row_order
    """)
    mentions = query(backend, f"""
        select count(*) as n, min(posted_at) as first_at, max(posted_at) as last_at
        from {_rel(backend, STAGING_SCHEMA, 'ust_staging', 'stg_mentionlytics__mentions')}
    """)[0]
    yt_rel = _rel(backend, STAGING_SCHEMA, "ust_staging", "stg_promo__youtube_videos")
    searched = query(backend, f"select max(searched_at) as s from {yt_rel} "
                              f"where promo_month = date '{promo_month}'")[0]["s"]
    return {"promo_month": promo_month, "rows": rows, "items": items, "mentions": mentions,
            "searched_at": searched}


# ─────────────────────────────────────────────────────────────────────────────
# Write
# ─────────────────────────────────────────────────────────────────────────────

def month_label(promo_month: str) -> str:
    return date.fromisoformat(promo_month[:10]).strftime("%b").upper()


def _fmt_date(v) -> str:
    if v is None or str(v) in ("", "NaT", "None"):
        return "n/a"
    d = v if isinstance(v, (date, datetime)) else datetime.fromisoformat(str(v)[:19])
    return f"{d:%b} {d.day}, {d.year}"


def footnote(data: dict) -> str:
    items = data["items"]
    src = sorted({i["source_file"] for i in items if i.get("source_file")})
    m = data["mentions"]
    scraped = (f"Rows with Source = Scraped came from YouTube searches on {_fmt_date(data['searched_at'])}, "
               f"keeping up to 3 of the highest-view videos that name the exact product."
               if data["searched_at"] else "No YouTube search has run for this month yet.")
    return (f"Promo item counts are distinct Item Nos. Source: {', '.join(src) or 'promo workbook'} "
            f"({len({i['item_no'] for i in items})} items) vs social listening "
            f"({int(m['n'] or 0):,} posts, {_fmt_date(m['first_at'])} – {_fmt_date(m['last_at'])}). "
            f"{scraped} YouTube shows views; TikTok shows likes. TikTok rows are added by hand "
            f"from the TikTok Search List sheet.")


def _none(v):
    if v is None:
        return None
    try:
        import math
        if isinstance(v, float) and math.isnan(v):
            return None
    except Exception:
        pass
    s = str(v)
    return None if s in ("", "NaT", "nan", "None") else v


def build_workbook(data: dict):
    from openpyxl import Workbook
    from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
    from openpyxl.utils import get_column_letter

    mon = month_label(data["promo_month"])
    thin = Side(style="thin", color=BORDER_COLOR)
    border = Border(left=thin, right=thin, top=thin, bottom=thin)
    body_font, head_font = Font(name="Arial", size=10), Font(name="Arial", size=10, bold=True, color="FFFFFF")
    head_fill = PatternFill("solid", fgColor=HEADER_FILL)
    head_align = Alignment(horizontal="center", vertical="center", wrap_text=True)
    body_align = Alignment(vertical="top", wrap_text=True)
    link_font = Font(name="Arial", size=10, color=LINK_COLOR, underline="single")

    def header_row(ws, headers, widths):
        for c, (h, w) in enumerate(zip(headers, widths), start=1):
            cell = ws.cell(row=1, column=c, value=h.replace("{MON}", mon))
            cell.font, cell.fill, cell.alignment, cell.border = head_font, head_fill, head_align, border
            ws.column_dimensions[get_column_letter(c)].width = w

    def body_cell(ws, r, c, value):
        cell = ws.cell(row=r, column=c, value=value)
        cell.font, cell.alignment, cell.border = body_font, body_align, border
        return cell

    wb = Workbook()

    # ── sheet 1 ──────────────────────────────────────────────────────────────
    ws = wb.active
    ws.title = SHEET_MAIN
    header_row(ws, HEADERS, WIDTHS)
    for r, row in enumerate(data["rows"], start=2):
        unmatched = row["match_status"] == "Unmatched"
        values = [
            row["promo_sheet"],
            int(row["item_no_int"]) if _none(row.get("item_no_int")) is not None else row["item_no"],
            (row["promo_description"] or "").strip(),
            _none(row["promo_size"]),
            _none(row["promo_code"]),
            row["match_status"],
        ] + ([None] * 9 if unmatched else [
            _none(row["matched_content_item"]),
            _none(row["channel"]),
            _none(row["profile"]),
            _none(row["post_date"]),
            _none(row["engagement_text"]),
            _none(row["caption"]),
            _none(row["link"]),
            _none(row["source"]),
            _none(row["match_note"]),
        ])
        for c, v in enumerate(values, start=1):
            cell = body_cell(ws, r, c, v)
            if c == 6:
                cell.font = Font(name="Arial", size=10, bold=True)
                cell.fill = PatternFill("solid", fgColor=STATUS_FILL.get(row["match_status"], "FFFFFF"))
            if c == 13 and v:
                cell.hyperlink = str(v)
                cell.font = link_font
    last = len(data["rows"]) + 1
    ws.freeze_panes = "D2"
    ws.auto_filter.ref = f"A1:O{last}"

    # ── sheet 2: Summary ─────────────────────────────────────────────────────
    sm = wb.create_sheet(SHEET_SUMMARY)
    header_row(sm, ["Match Status", "Promo Items", "Matched Posts (rows)"], [16, 14, 22])
    q = f"'{SHEET_MAIN}'"
    rng_b, rng_f = f"{q}!$B$2:$B${FORMULA_ROWS}", f"{q}!$F$2:$F${FORMULA_ROWS}"
    for r, status in enumerate(["Exact", "Close", "Unmatched"], start=2):
        body_cell(sm, r, 1, status)
        # distinct Item No. among rows with this status (blank rows count 0)
        body_cell(sm, r, 2, f'=SUMPRODUCT(({rng_f}=A{r})/COUNTIFS({rng_b},{rng_b}&"",{rng_f},{rng_f}&""))')
        body_cell(sm, r, 3, f'=IF(A{r}="Unmatched",0,COUNTIF({q}!F:F,A{r}))')
    body_cell(sm, 5, 1, "Total").font = Font(name="Arial", size=10, bold=True)
    body_cell(sm, 5, 2, "=SUM(B2:B4)")
    body_cell(sm, 5, 3, "=SUM(C2:C4)")
    note = sm.cell(row=7, column=1, value=footnote(data))
    note.font = Font(name="Arial", size=10, italic=True)
    note.alignment = Alignment(vertical="top", wrap_text=False)

    # ── sheet 3: TikTok Search List ──────────────────────────────────────────
    tk = wb.create_sheet(SHEET_TIKTOK)
    header_row(tk, TIKTOK_HEADERS, TIKTOK_WIDTHS)
    status_by_row = {}
    for row in data["rows"]:
        key = (row["promo_sheet"], row["row_order"])
        status_by_row.setdefault(key, (row["match_status"], row["source"]))
    r = 2
    for it in data["items"]:
        status, source = status_by_row.get((it["promo_sheet"], it["row_order"]), ("Unmatched", None))
        if not it.get("is_branded") or source == "Social Listening":
            continue                         # unbranded, or social listening already matched it
        phrases = split_terms(it.get("search_queries"))
        current = "Unmatched" if status == "Unmatched" else f"{status} (YouTube)"
        values = [
            int(it["item_no"]) if str(it["item_no"]).isdigit() else it["item_no"],
            (it["promo_description"] or "").strip(), _none(it.get("promo_size")),
            _none(it.get("brand")), _none(it.get("product")), _none(it.get("flavor_variant")),
            current, "\n".join(phrases),
            ", ".join(split_terms(it.get("brand_terms"))),
            ", ".join(split_terms(it.get("flavor_terms"))) or "(no flavor to require)",
            ", ".join(split_terms(it.get("negative_terms"))) or "-",
            f"https://www.tiktok.com/search/video?q={urllib.parse.quote(phrases[0])}" if phrases else None,
        ]
        for c, v in enumerate(values, start=1):
            cell = body_cell(tk, r, c, v)
            if c == 12 and v:
                cell.hyperlink, cell.font = v, link_font
        r += 1
    tk.freeze_panes = "C2"
    tk.auto_filter.ref = f"A1:L{max(r - 1, 1)}"
    return wb


def output_name(promo_month: str) -> str:
    return f"UST_{month_label(promo_month)}_Promo_Social_Listening_Match.xlsx"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--backend", choices=["local", "databricks"], default="local")
    ap.add_argument("--promo-month", help="YYYY-MM-01 (default: the latest month in the mart)")
    ap.add_argument("--out-dir", help="folder to write to (default: <local_data_root>/promo/output, "
                                      f"or {DBX_OUT_DIR} on Databricks)")
    args = ap.parse_args(argv)

    data = read_inputs(args.backend, args.promo_month)
    out_dir = Path(args.out_dir) if args.out_dir else (
        Path(DBX_OUT_DIR) if args.backend == "databricks" else local_data_root() / "promo" / "output")
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / output_name(data["promo_month"])
    # An .xlsx is a zip, and writing one seeks back to patch headers. A Unity Catalog
    # Volume is write-once, sequential storage: saving straight to it fails with
    # "[Errno 5] Input/output error" (first Databricks run, 2026-10-07). So the workbook
    # is built on local disk and then copied over in one sequential write.
    with tempfile.TemporaryDirectory() as tmp:
        local = Path(tmp) / path.name
        build_workbook(data).save(local)
        shutil.copyfile(local, path)
    statuses = {}
    for row in data["rows"]:
        statuses.setdefault(row["match_status"], set()).add(row["item_no"])
    print(f"wrote {path}\n  {len(data['rows'])} rows; "
          + ", ".join(f"{k} {len(v)} items" for k, v in sorted(statuses.items())))


if __name__ == "__main__":
    main()
