"""Write UST_<MON>_Promo_Social_Listening_Match.xlsx from mart_promo_social_match (step 5).

Four sheets:
  1. "Summary"                    opens first. Counts per status, per promo sheet, per
                                  channel and per column block, all LIVE formulas over
                                  sheet 2, so results added afterwards (TikTok, RedNote) are
                                  counted without re-running anything; then the items
                                  nothing was found for, as of the export.
  2. "Promo vs Social Listening"  ONE ROW PER ITEM (since 2026-10-20; before, one row per
                                  post). Match Status is the item's status; beside it,
                                  "On Trending Social" (Mentionlytics) and "Direct
                                  Scraping" (TikTok, YouTube & RedNote) show what each source
                                  found, and Posts counts the item's results (a live
                                  formula). Then the RESULTS, WIDE: Trending Social 1-3,
                                  then a block of 3 cells per search language (English,
                                  Thai, Vietnamese, Chinese: the languages searched
                                  this month), so one language's finds never push out
                                  another's. The Chinese block is filled only by the
                                  RedNote step: YouTube and TikTok search no Chinese. A result cell reads "YouTube · 176,000 views ·
                                  900 likes · 2022-03-14", links to the post, is coloured
                                  by its status, and carries the caption and match note as
                                  a cell note. "–" = not searched in that language; blank
                                  = searched, nothing found.
  3. "TikTok Search List"         the items to search on TikTok by hand with Claude in
                                  Chrome (prompt: scripts/promo/prompts/tiktok_promo_search.md):
                                  every branded item social listening did not match,
                                  plus every UST own-brand item and every frozen item
                                  with no brand, with search phrases (each tagged with
                                  its language block; no Chinese), required words,
                                  exclusions and a TikTok search link.
  4. "RedNote Search List"        the same items, with their CHINESE phrases only, for
                                  RedNote (Xiaohongshu) by hand
                                  (prompt: scripts/promo/prompts/rednote_promo_search.md).
                                  An item with no Chinese phrase is left off.
  Each prompt has Claude delete its sheet when done, leaving the 2-sheet deliverable.

    python scripts/promo/export_promo_social_match.py                       # latest month, local
    python scripts/promo/export_promo_social_match.py --promo-month 2026-10-01 --out-dir C:/somewhere
    python scripts/promo/export_promo_social_match.py --backend databricks  # -> the promo_output Volume
"""

from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
import urllib.parse
from datetime import date, datetime
from pathlib import Path

sys.path.insert(0, str(Path.cwd() / "scripts" / "promo"))
try:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
except NameError:
    pass

from promo_common import (  # noqa: E402
    INTERMEDIATE_SCHEMA, LANGUAGES, REPORTING_SCHEMA, STAGING_SCHEMA, dbt_var, flag, local_data_root,
    phrase_language, platform_phrases, product_card_lines, query, search_phrases, split_terms,
)

DBX_OUT_DIR = "/Volumes/ust_databricks/social/promo_output"
SHEET_MAIN, SHEET_SUMMARY = "Promo vs Social Listening", "Summary"
SHEET_TIKTOK, SHEET_REDNOTE = "TikTok Search List", "RedNote Search List"

# Item columns, then Posts, then the result blocks. The Summary's formulas address
# columns by letter (A = Promo Sheet, F = Match Status, I = Posts, J onward = results).
SOCIAL_COL, SCRAPED_COL = "On Trending Social (Mentionlytics)", "Direct Scraping (TikTok, YouTube & RedNote)"
ITEM_HEADERS = ["Promo Sheet", "Item No.", "{MON} Promo Item", "Size", "Promo Code", "Match Status",
                SOCIAL_COL, SCRAPED_COL, "Posts"]
ITEM_WIDTHS = [13, 10, 32, 15, 10, 12, 16, 16, 8]
SLOTS = 3                    # result cells per block: var promo_scraped_max_per_item
SOCIAL_BLOCK = "Trending Social"
RESULT_WIDTH = 27
NOT_SEARCHED = "–"           # an en dash: the item was not searched in this language
# status -> (fill, font colour)
# ARGB, opaque, as Excel writes them (openpyxl would store a 6-digit RGB as 00RRGGBB)
STATUS_STYLE = {"Exact": ("FFC6EFCE", "FF006100"), "Close": ("FFFFEB9C", "FF9C5700"),
                "Unmatched": ("FFEDEDED", "FF595959")}
HEADER_FILL, BORDER_COLOR, LINK_COLOR = "FF1F4E78", "FFBFBFBF", "FF0563C1"
BLOCK_FILLS = ("FF1F4E78", "FF2E75B6")   # result blocks' headers alternate, to read as blocks
BAND_FILL = "FFEEF3F8"       # every other item
MUTED, NOTE_GREY = "FF808080", "FF595959"
HEADER_HEIGHT, ROW_HEIGHT, SUMMARY_ROW_HEIGHT = 27.75, 39.75, 15
FORMULA_ROWS = 5000          # Summary formulas cover this many sheet-1 rows

# the hand-search sheets: (sheet, platform for platform_phrases, name, search URL + phrase)
SEARCH_LISTS = [(SHEET_TIKTOK, "tiktok", "TikTok", "https://www.tiktok.com/search/video?q="),
                (SHEET_REDNOTE, "rednote", "RedNote", "https://www.xiaohongshu.com/search_result?keyword=")]
SEARCH_HEADERS = ["Item No.", "{MON} Promo Item", "Size", "Brand", "Product", "Flavor / Variant",
                  "Current Status", "Search Phrases", "Must Mention (brand)", "Flavor Words",
                  "Exclude If", "{PLATFORM} Search Link", "Product Card", "Photo"]
SEARCH_WIDTHS = [10, 34, 16, 14, 22, 22, 14, 40, 36, 36, 30, 45, 60, 18]
PHOTO_HEIGHT = 110           # px: a list row with a photo is this tall


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
    scraped = (f"The language columns came from YouTube searches on {_fmt_date(data['searched_at'])}: "
               f"each holds up to 3 videos that name the exact product, found by that language's "
               f"search phrase, highest views first, then likes + comments; only videos posted in the "
               f"past 2 years when there are any, else older ones (marked \"older\")."
               if data["searched_at"] else "No YouTube search has run for this month yet.")
    scraped += " The Chinese columns come only from RedNote (Xiaohongshu), searched by hand."
    return (f"One row per promo item. Source: {', '.join(src) or 'promo workbook'} "
            f"({len({i['item_no'] for i in items})} items) vs social listening "
            f"({int(m['n'] or 0):,} posts, {_fmt_date(m['first_at'])} – {_fmt_date(m['last_at'])}). "
            f"{scraped} {NOT_SEARCHED} = not searched in that language; blank = searched, nothing found. "
            f"Hover a result for its caption. YouTube shows views; TikTok and RedNote show likes. TikTok "
            f"and RedNote results are added by hand from their Search List sheets.")


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


def _count(v):
    """A metric as an integer for the Views / Likes columns, or None when missing or 0."""
    v = _none(v)
    if v is None:
        return None
    try:
        n = int(float(v))
    except (TypeError, ValueError):
        return None
    return n if n > 0 else None


def on_search_list(it: dict, social_status) -> bool:
    """Whether an item is searched by hand on TikTok and RedNote (the Search List
    sheets; RedNote only when it has a Chinese phrase): every branded item social
    listening did not match, plus every own-brand item and every frozen item with no
    brand that has phrases to search with. The same items, less any that are not own
    brands, are the ones youtube_search.py searches."""
    branded, frozen = flag(it.get("is_branded")), flag(it.get("is_frozen"))
    if not (branded or frozen) or (social_status and not flag(it.get("is_own_brand"))):
        return False
    # a frozen item reviewed before v4 has no queries to search with
    return branded or bool(search_phrases(it.get("search_queries")))


def item_results(data: dict) -> list[dict]:
    """The mart's rows (one per post) grouped into items, in workbook order: the
    item's first row, its social listening posts, its scraped videos by search
    language, and the languages it is searched in (from its phrases)."""
    by_key = {(i["promo_sheet"], i["row_order"]): i for i in data["items"]}
    out, index = [], {}
    for row in data["rows"]:
        key = (row["promo_sheet"], row["row_order"])
        if key not in index:
            it = by_key.get(key, {})
            searched = on_search_list(it, _none(row.get("social_match_status")))
            index[key] = {"row": row, "all": [], "social": [], "scraped": {},
                          "searched_langs": {phrase_language(p) for p in search_phrases(it.get("search_queries"))}
                                            if searched else set()}
            out.append(index[key])
        entry = index[key]
        if row["match_status"] == "Unmatched":
            continue
        entry["all"].append(row)
        if row.get("source") == "Scraped":
            entry["scraped"].setdefault(_none(row.get("search_language")) or "English", []).append(row)
        else:
            entry["social"].append(row)
    return out


def result_languages(items: list[dict]) -> list[str]:
    """The language blocks this month needs, in LANGUAGES order: every language an item
    was searched in or has a result in."""
    used = set().union(*(set(it["scraped"]) | it["searched_langs"] for it in items)) if items else set()
    return [lang for lang in LANGUAGES if lang in used] + sorted(used - set(LANGUAGES))


def result_text(m: dict) -> str:
    """A result cell: "YouTube · 176,000 views · 900 likes · 2022-03-14"."""
    engagement = (_none(m.get("engagement_text")) or "").replace(", ", " · ")
    date_ = str(m["post_date"])[:10] if _none(m.get("post_date")) else None
    parts = [_none(m.get("channel")), engagement or None, date_]
    if str(m.get("match_note") or "").startswith("Older than"):
        parts.append("older")
    return " · ".join(str(p) for p in parts if p)


def result_note(m: dict) -> str:
    """A result cell's note: what the post calls the product, who posted it, the
    caption, and why it matched."""
    caption = str(_none(m.get("caption")) or "")
    caption = caption[:500] + ("…" if len(caption) > 500 else "")
    return "\n\n".join(str(p) for p in (
        _none(m.get("matched_content_item")), _none(m.get("profile")), caption or None,
        _none(m.get("match_note"))) if p)


def card_text(it: dict) -> str | None:
    """The item's product card and description, for the hand searches."""
    lines = product_card_lines(it)
    if _none(it.get("short_description")):
        lines.append(f"description: {it['short_description']}")
    if _none(it.get("selling_points")):
        lines.append(f"selling points: {it['selling_points']}")
    return "\n".join(lines) or None


def _photo_image(path):
    """The product photo as an openpyxl image sized for a list row, or None (no
    photo, unreadable, or Pillow missing: the list then has the card text only)."""
    if not _none(path):
        return None
    try:
        import io
        from openpyxl.drawing.image import Image as XLImage
        img = XLImage(io.BytesIO(Path(str(path)).read_bytes()))
    except Exception:
        return None
    scale = PHOTO_HEIGHT / max(img.height, 1)
    img.width, img.height = int(img.width * scale), PHOTO_HEIGHT
    return img


def build_workbook(data: dict):
    from openpyxl import Workbook
    from openpyxl.comments import Comment
    from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
    from openpyxl.utils import get_column_letter

    mon = month_label(data["promo_month"])
    thin = Side(style="thin", color=BORDER_COLOR)
    border = Border(left=thin, right=thin, top=thin, bottom=thin)
    body_font, bold_font = Font(name="Arial", size=10), Font(name="Arial", size=10, bold=True)
    head_font = Font(name="Arial", size=10, bold=True, color="FFFFFFFF")
    head_fill = PatternFill("solid", fgColor=HEADER_FILL)
    band_fill = PatternFill("solid", fgColor=BAND_FILL)
    wrap_top = Alignment(vertical="top", wrap_text=True)
    link_font = Font(name="Arial", size=10, color=LINK_COLOR, underline="single")

    def header_row(ws, headers, widths, row=1, align=None):
        for c, h in enumerate(headers, start=1):
            cell = ws.cell(row=row, column=c, value=h.replace("{MON}", mon))
            cell.font, cell.fill, cell.border = head_font, head_fill, border
            cell.alignment = align or Alignment(vertical="center", wrap_text=True)
        for c, w in enumerate(widths or [], start=1):
            ws.column_dimensions[get_column_letter(c)].width = w

    def body_cell(ws, r, c, value, align=wrap_top):
        cell = ws.cell(row=r, column=c, value=value)
        cell.font, cell.alignment, cell.border = body_font, align, border
        return cell

    wb = Workbook()
    sm = wb.active                          # Summary is the FIRST sheet, and opens first
    sm.title = SHEET_SUMMARY
    ws = wb.create_sheet(SHEET_MAIN)

    # ── Promo vs Social Listening: one row per item, results wide ────────────
    items = item_results(data)
    langs = result_languages(items)
    blocks = [SOCIAL_BLOCK] + langs
    headers = ITEM_HEADERS + [f"{b} {n}" for b in blocks for n in range(1, SLOTS + 1)]
    header_row(ws, headers, ITEM_WIDTHS + [RESULT_WIDTH] * (len(blocks) * SLOTS))
    ws.row_dimensions[1].height = HEADER_HEIGHT
    first_res = len(ITEM_HEADERS) + 1
    for b in range(len(blocks)):             # each block's headers in turn, so blocks read apart
        for n in range(SLOTS):
            ws.cell(row=1, column=first_res + b * SLOTS + n).fill = \
                PatternFill("solid", fgColor=BLOCK_FILLS[b % 2])
    last_col = get_column_letter(len(headers))
    res_cols = f"{get_column_letter(first_res)}{{r}}:{last_col}{{r}}"
    centred = Alignment(horizontal="center", vertical="top")
    muted_font = Font(name="Arial", size=10, color=MUTED)

    for r, it in enumerate(items, start=2):
        band = r % 2 == 1                    # every other item
        row = it["row"]
        unmatched = row["item_match_status"] == "Unmatched"
        values = [row["promo_sheet"],
                  int(row["item_no_int"]) if _none(row.get("item_no_int")) is not None else row["item_no"],
                  (row["promo_description"] or "").strip(), _none(row["promo_size"]), _none(row["promo_code"]),
                  row["item_match_status"], _none(row.get("social_match_status")),
                  _none(row.get("scraped_match_status")),
                  # live, so results the TikTok and RedNote steps add are counted
                  f'=COUNTA({res_cols.format(r=r)})-COUNTIF({res_cols.format(r=r)},"{NOT_SEARCHED}")']
        for c, v in enumerate(values, start=1):
            cell = body_cell(ws, r, c, v, centred if c == len(values) else wrap_top)
            if band:
                cell.fill = band_fill
            if unmatched:
                cell.font = muted_font
            if c in (6, 7, 8) and v:         # the three status columns
                fill, colour = STATUS_STYLE.get(v, ("FFFFFFFF", "FF000000"))
                cell.fill = PatternFill("solid", fgColor=fill)
                cell.font = Font(name="Arial", size=10, bold=True, color=colour)
        for b, block in enumerate(blocks):
            found = it["social"] if block == SOCIAL_BLOCK else it["scraped"].get(block, [])
            searched = block == SOCIAL_BLOCK or block in it["searched_langs"] or found
            for n in range(SLOTS):
                cell = body_cell(ws, r, first_res + b * SLOTS + n, None)
                if band:
                    cell.fill = band_fill
                if n < len(found):
                    m = found[n]
                    text = result_text(m)
                    if n == SLOTS - 1 and len(found) > SLOTS:
                        text += f" (+{len(found) - SLOTS} more)"
                    cell.value = text
                    fill, _ = STATUS_STYLE.get(m["match_status"], ("FFFFFFFF", None))
                    cell.fill = PatternFill("solid", fgColor=fill)
                    cell.font = link_font
                    if _none(m.get("link")):
                        cell.hyperlink = str(m["link"])
                    note = Comment(result_note(m), "UST promo match")
                    note.width, note.height = 320, 220
                    cell.comment = note
                elif n == 0 and not searched:
                    cell.value, cell.font, cell.alignment = NOT_SEARCHED, muted_font, centred
        ws.row_dimensions[r].height = ROW_HEIGHT
    last = len(items) + 1
    ws.freeze_panes = "D2"
    ws.auto_filter.ref = f"A1:{last_col}{last}"

    # ── Summary ──────────────────────────────────────────────────────────────
    # Every count is a LIVE formula over the main sheet, so results the TikTok and
    # RedNote steps add are counted without re-running anything. One row per item, so an item
    # count is a plain COUNTIF on Match Status (F), and a post count sums Posts (I).
    q = f"'{SHEET_MAIN}'"
    rng_a, rng_f, rng_i = (f"{q}!${c}$2:${c}${FORMULA_ROWS}" for c in "AFI")
    rng_res = f"{q}!${get_column_letter(first_res)}$2:${last_col}${FORMULA_ROWS}"
    plain = Alignment(vertical="bottom")
    statuses = ["Exact", "Close", "Unmatched"]

    def title(r, text):
        sm.cell(row=r, column=1, value=text).font = Font(name="Arial", size=11, bold=True)

    def total_row(r, first, last_r, cols):
        body_cell(sm, r, 1, "Total", plain).font = bold_font
        for c in range(2, cols + 1):
            col = get_column_letter(c)
            body_cell(sm, r, c, f"=SUM({col}{first}:{col}{last_r})", plain)

    header_row(sm, ["Match Status", "Promo Items", "Matched Posts"], [16, 34, 22, 10],
               align=Alignment(horizontal="center", vertical="center", wrap_text=True))
    for r, status in enumerate(statuses, start=2):
        body_cell(sm, r, 1, status)
        body_cell(sm, r, 2, f"=COUNTIF({rng_f},A{r})")
        body_cell(sm, r, 3, f"=SUMIF({rng_f},A{r},{rng_i})")
    body_cell(sm, 5, 1, "Total").font = bold_font
    body_cell(sm, 5, 2, "=SUM(B2:B4)")
    body_cell(sm, 5, 3, "=SUM(C2:C4)")
    note = sm.cell(row=7, column=1, value=footnote(data))
    note.font = Font(name="Arial", size=10, italic=True)
    note.alignment = Alignment(vertical="top", wrap_text=False)

    # promo items by sheet, one column per promo sheet in workbook order
    sheets = list(dict.fromkeys(it["row"]["promo_sheet"] for it in items))
    title(9, "Promo items by sheet")
    header_row(sm, ["Match Status"] + sheets + ["Total"], None, row=10, align=plain)
    for i, status in enumerate(statuses):
        r = 11 + i
        body_cell(sm, r, 1, status, plain)
        for c, sheet in enumerate(sheets, start=2):
            body_cell(sm, r, c, f'=COUNTIFS({rng_a},"{sheet}",{rng_f},$A{r})', plain)
        body_cell(sm, r, len(sheets) + 2,
                  f"=SUM(B{r}:{get_column_letter(len(sheets) + 1)}{r})", plain)
    total_row(14, 11, 13, len(sheets) + 2)

    # matched posts by channel: a result cell starts with its channel and " · ";
    # TikTok and RedNote are always listed, because their hand steps add them
    channels = sorted({str(m["channel"]) for it in items for m in it["all"] if _none(m.get("channel"))}
                      | {"TikTok", "RedNote"}, key=str.casefold)
    title(16, "Matched posts by channel")
    header_row(sm, ["Channel", "Posts"], None, row=17, align=plain)
    for i, channel in enumerate(channels):
        r = 18 + i
        body_cell(sm, r, 1, channel, plain)
        body_cell(sm, r, 2, f'=COUNTIF({rng_res},$A{r}&" ·*")', plain)
    end = 18 + len(channels)
    total_row(end, 18, end - 1, 2)

    # matched posts by column block: Trending Social, then each search language
    start = end + 2
    title(start, "Matched posts by search language")
    header_row(sm, ["Column Block", "Posts"], None, row=start + 1, align=plain)
    for i, block in enumerate(blocks):
        r = start + 2 + i
        c0 = first_res + i * SLOTS
        rng = f"{q}!${get_column_letter(c0)}$2:${get_column_letter(c0 + SLOTS - 1)}${FORMULA_ROWS}"
        body_cell(sm, r, 1, block, plain)
        body_cell(sm, r, 2, f'=COUNTA({rng})-COUNTIF({rng},"{NOT_SEARCHED}")', plain)
    end = start + 2 + len(blocks)
    total_row(end, start + 2, end - 1, 2)

    # the items nothing was found for, as of this export (the hand steps update it)
    start = end + 2
    title(start, "Unmatched promo items (no post found)")
    header_row(sm, ["Item No.", f"{mon} Promo Item", "Promo Sheet"], None, row=start + 1, align=plain)
    r = start + 2
    for it in items:
        row = it["row"]
        if row["item_match_status"] == "Unmatched":
            item_no = int(row["item_no_int"]) if _none(row.get("item_no_int")) is not None else row["item_no"]
            body_cell(sm, r, 1, item_no, plain)
            body_cell(sm, r, 2, (row["promo_description"] or "").strip(), plain)
            body_cell(sm, r, 3, row["promo_sheet"], plain)
            r += 1
    tail = sm.cell(row=r, column=1, value="List captured when the workbook was built; to see current gaps, "
                                          f"filter Match Status = Unmatched on the {SHEET_MAIN} tab.")
    tail.font = Font(name="Arial", size=9, italic=True, color=NOTE_GREY)
    for i in range(1, r + 1):
        if any(sm.cell(row=i, column=c).value is not None for c in range(1, 5)):
            sm.row_dimensions[i].height = SUMMARY_ROW_HEIGHT

    # ── TikTok and RedNote Search Lists (each deleted by its step when done) ─
    status_by_row = {}
    for row in data["rows"]:
        key = (row["promo_sheet"], row["row_order"])
        status_by_row.setdefault(key, (_none(row.get("social_match_status")),
                                       _none(row.get("scraped_match_status"))))
    for sheet, platform, name, search_url in SEARCH_LISTS:
        sl = wb.create_sheet(sheet)
        header_row(sl, [h.replace("{PLATFORM}", name) for h in SEARCH_HEADERS], SEARCH_WIDTHS,
                   align=Alignment(horizontal="center", vertical="center", wrap_text=True))
        r = 2
        for it in data["items"]:
            social, scraped = status_by_row.get((it["promo_sheet"], it["row_order"]), (None, None))
            phrases = platform_phrases(it.get("search_queries"), platform)
            # RedNote searches only Chinese: an item with no Chinese phrase has nothing to search
            if not on_search_list(it, social) or (platform == "rednote" and not phrases):
                continue
            branded = flag(it.get("is_branded"))
            must_mention = (", ".join(split_terms(it.get("brand_terms"))) if branded else
                            "(no brand: frozen product) " + ", ".join(split_terms(dbt_var("promo_frozen_terms", ["frozen"]))))
            current = "; ".join([f"{social} (On Trending Social)"] * bool(social)
                                + [f"{scraped} (YouTube)"] * bool(scraped)) or "Unmatched"
            values = [
                int(it["item_no"]) if str(it["item_no"]).isdigit() else it["item_no"],
                (it["promo_description"] or "").strip(), _none(it.get("promo_size")),
                _none(it.get("brand")), _none(it.get("product")), _none(it.get("flavor_variant")),
                # each tagged with its language block on the main sheet
                current, "\n".join(f"[{phrase_language(p)}] {p}" for p in phrases),
                must_mention,
                ", ".join(split_terms(it.get("flavor_terms"))) or "(no flavor to require)",
                ", ".join(split_terms(it.get("negative_terms"))) or "-",
                f"{search_url}{urllib.parse.quote(phrases[0])}" if phrases else None,
                card_text(it), None,
            ]
            for c, v in enumerate(values, start=1):
                cell = body_cell(sl, r, c, v)
                if c == 12 and v:
                    cell.hyperlink, cell.font = v, link_font
            photo = _photo_image(it.get("photo_path"))
            if photo:
                sl.add_image(photo, f"N{r}")
                sl.row_dimensions[r].height = PHOTO_HEIGHT * 0.75 + 4     # px -> points
            r += 1
        sl.freeze_panes = "C2"
        sl.auto_filter.ref = f"A1:N{max(r - 1, 1)}"
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
        statuses.setdefault(row["item_match_status"], set()).add(row["item_no"])
    print(f"wrote {path}\n  {len(data['rows'])} rows; "
          + ", ".join(f"{k} {len(v)} items" for k, v in sorted(statuses.items())))


if __name__ == "__main__":
    main()
