"""Product cards: drafting (with a stub model), the card in the judge's prompt, the
photos sent to the judge, and the card + photo on the hand-search lists.
Run:  python -m pytest scripts/promo/tests
"""

import io
import json
import sys
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from openpyxl import load_workbook  # noqa: E402

import draft_product_cards as dc  # noqa: E402
import export_promo_social_match as ex  # noqa: E402
import promo_common as pc  # noqa: E402

LAYS_REPLY = {
    "brand_on_pack": "Lay's", "product_on_pack": "Bánh snack khoai tây (potato chips)",
    "flavor_on_pack": "Vị Sườn Nướng BBQ Brazil / Brazil BBQ Pork Rib", "pack": "bag, Party Pack, 90 g",
    "market": "Vietnam", "look": "orange-yellow bag, Lay's logo in a green ring, pork ribs pictured",
    "pack_text": ["Vị Sườn Nướng BBQ Brazil", "Brazil BBQ Pork Rib", "Party Pack", "Càng ăn càng cuốn"],
    "lookalikes": ["Lay's Prawns w/ Cheese (same promo)", "Thai Lay's 10-baht packs"],
    "search_phrases": ["Lay's sườn nướng BBQ Brazil", "lay's brazil bbq pork rib", "a third one"],
    "flavor_terms": ["sườn nướng", "brazil bbq pork rib"], "product_terms": ["khoai tây"],
    "notes": None,
}


def _png():
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (8, 8), "orange").save(buf, format="PNG")
    return buf.getvalue()


def _stub(reply, seen):
    def create(**kw):
        seen.append(kw)
        return SimpleNamespace(content=[SimpleNamespace(text=json.dumps(reply))], stop_reason="end_turn")
    return SimpleNamespace(messages=SimpleNamespace(create=create))


def _row(tmp_path, photo=True):
    path = None
    if photo:
        path = tmp_path / "37545.png"
        path.write_bytes(_png())
    row = {"item_no": "37545", "promo_description": "LAY'S BBQ PORK RIBS FLAVOR", "promo_size": "40X3.17OZ",
           "origin_code": "VN", "short_description": "Crispy potato chips with sweet and savory barbecue pork rib flavor.",
           "selling_points": "Sweet and Savory Barbecue Taste | Big Sharing Party Pack", "photo_path": str(path) if path else None}
    row["_photo"] = dc._photo_bytes(row["photo_path"])
    row["_fingerprint"] = dc.input_fingerprint(row, row["_photo"])
    return row


def test_card_is_drafted_from_the_photo_and_text(tmp_path):
    seen = []
    row = _row(tmp_path)
    others = [row, {"item_no": "37546", "promo_description": "LAY'S PRAWNS W/ CHEESE FLAVOR", "promo_size": "40X3.17OZ"}]
    card = dc.draft_one(_stub(LAYS_REPLY, seen), "m", "m/v1", row, others)
    # the photo goes first, then the record, which lists the month's other items
    content = seen[0]["messages"][0]["content"]
    assert content[0]["type"] == "image" and content[0]["source"]["media_type"] == "image/png"
    assert "37546 LAY'S PRAWNS W/ CHEESE FLAVOR" in content[1]["text"] and "photo: attached" in content[1]["text"]
    assert card["flavor_on_pack"] == "Vị Sườn Nướng BBQ Brazil / Brazil BBQ Pork Rib"
    assert card["pack_text"].split("|")[:2] == ["Vị Sườn Nướng BBQ Brazil", "Brazil BBQ Pork Rib"]
    # at most 2 search phrases, lowercased; terms lowercased
    assert card["search_phrases"] == "lay's sườn nướng bbq brazil|lay's brazil bbq pork rib"
    assert card["flavor_terms"] == "sườn nướng|brazil bbq pork rib"
    assert card["has_photo"] == "true" and card["card_version"] == "m/v1"
    assert card["input_fingerprint"] == row["_fingerprint"]
    assert set(card) == set(pc.LANDING["product_cards"]["columns"])


def test_card_without_a_photo_is_text_only(tmp_path):
    seen = []
    row = _row(tmp_path, photo=False)
    card = dc.draft_one(_stub(LAYS_REPLY, seen), "m", "m/v1", row, [row])
    assert isinstance(seen[0]["messages"][0]["content"], str)
    assert "photo: none" in seen[0]["messages"][0]["content"] and card["has_photo"] == "false"


def test_fingerprint_changes_with_the_photo_or_text(tmp_path):
    row = _row(tmp_path)
    base = dc.input_fingerprint(row, row["_photo"])
    assert dc.input_fingerprint(row, row["_photo"] + b"x") != base
    assert dc.input_fingerprint({**row, "selling_points": "other"}, row["_photo"]) != base
    assert dc.input_fingerprint(dict(row), row["_photo"]) == base
    assert dc._has_detail({"photo_path": None, "short_description": None}) is False
    assert dc._has_detail({"photo_path": None, "notes": None, "detail_notes": "x"}) is True


def test_the_judge_gets_the_card_and_the_photos():
    item = {"promo_description": "LAY'S STAXT BBQ FLAVOR", "brand": "Lay's", "product": "potato chips",
            "flavor_variant": "bbq", "card_brand_on_pack": "Lay's", "card_flavor_on_pack": "Barbecue / Vị Thịt Nướng BBQ",
            "card_pack": "canister, Family Pack, 145 g", "card_market": "Vietnam",
            "card_lookalikes": "Lay's Stax Mesquite Barbecue (US red canister)|Lay's Stax Smokin' BBQ"}
    text = pc.judge_user_prompt(item, {"channel": "YouTube video", "text": "t"}, {})
    assert "PRODUCT CARD" in text and "flavor on pack: Barbecue / Vị Thịt Nướng BBQ" in text
    assert "LOOKALIKES (not this item): Lay's Stax Mesquite Barbecue (US red canister); Lay's Stax Smokin' BBQ" in text
    assert "PRODUCT CARD" not in pc.judge_user_prompt({"brand": "x"}, {"text": "t"}, {})
    photo, thumb = pc.image_block(b"\x89PNG", "png"), pc.image_block(b"\xff\xd8", "jpeg")
    content = pc._judge_content(item, {"text": "t", "images": [photo, thumb]}, {})
    assert [b["type"] for b in content] == ["image", "image", "text"]
    assert isinstance(pc._judge_content(item, {"text": "t"}, {}), str)       # no photo: text only
    assert pc.image_block(b"x" * (pc.MAX_IMAGE_BYTES + 1), "png") is None      # too big to send
    assert pc.read_photo(None) is None and pc.read_photo("C:/no/such/file.png") is None


def test_the_lists_show_the_card_and_the_photo(tmp_path):
    photo = tmp_path / "37545.png"
    photo.write_bytes(_png())
    item = {"promo_sheet": "NOV NEW", "row_order": 1, "item_no": "37545", "promo_description": "LAY'S BBQ PORK RIBS FLAVOR",
            "promo_size": "40X3.17OZ", "is_branded": True, "brand": "Lay's", "product": "potato chips",
            "flavor_variant": "bbq pork ribs", "brand_terms": "lay's", "flavor_terms": "bbq pork ribs|sườn nướng",
            "negative_terms": None, "source_file": "UST 2026 NOV PROMO INPUT.xlsx", "photo_path": str(photo),
            "search_queries": "lay's sườn nướng bbq brazil|lay's brazil bbq pork rib|乐事 烤排骨",
            "card_flavor_on_pack": "Vị Sườn Nướng BBQ Brazil", "card_pack": "bag, Party Pack, 90 g",
            "short_description": "Crispy potato chips."}
    row = {"promo_sheet": "NOV NEW", "row_order": 1, "match_rank": 1, "item_no": "37545", "item_no_int": 37545,
           "promo_description": "LAY'S BBQ PORK RIBS FLAVOR", "promo_size": "40X3.17OZ", "promo_code": None,
           "match_status": "Unmatched", "item_match_status": "Unmatched", "social_match_status": None,
           "scraped_match_status": None, "source": None}
    data = {"promo_month": "2026-11-01", "rows": [row], "items": [item],
            "mentions": {"n": 1, "first_at": datetime(2026, 2, 20), "last_at": datetime(2026, 9, 29)},
            "searched_at": None}
    path = tmp_path / "out.xlsx"
    ex.build_workbook(data).save(path)
    wb = load_workbook(path)
    tk, rn = wb["TikTok Search List"], wb["RedNote Search List"]
    assert [c.value for c in tk[1]][-2:] == ["Product Card", "Photo"]
    # the card's phrases come first; TikTok gets the non-Chinese ones, RedNote the Chinese one
    assert tk["H2"].value == "[Vietnamese] lay's sườn nướng bbq brazil\n[English] lay's brazil bbq pork rib"
    assert rn["H2"].value == "[Chinese] 乐事 烤排骨"
    assert "flavor on pack: Vị Sườn Nướng BBQ Brazil" in tk["M2"].value and "description: Crispy" in tk["M2"].value
    assert len(tk._images) == 1 and tk._images[0].anchor._from.col == 13      # the photo, on column N
    assert tk.auto_filter.ref == "A1:N2"
