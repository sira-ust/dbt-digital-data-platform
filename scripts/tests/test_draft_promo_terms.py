"""Brand codes in the term drafter: which codes a description carries, and what a
brand or frozen code forces on the LLM's draft. No database or LLM needed: the
model is a stub that returns a fixed reply. Run:  python -m pytest scripts/tests
"""

import json
import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest  # noqa: E402

import draft_promo_terms as d  # noqa: E402


@pytest.fixture(scope="module")
def codes():
    return d.load_codes()                    # the real list, from dbt_project.yml


@pytest.mark.parametrize("description, expected", [
    ("D FZ STIR-FRIED EEL", ["D FZ", "FZ"]),          # two-word code: Dragonfly frozen
    ("FZ DF SESAME DONUT (PANDAN)", ["DF", "FZ"]),
    ("DF FZ NIPA PALM", ["DF", "FZ"]),
    ("FZ YELLOW MINI PANCAKE", ["FZ"]),
    ("FROZEN YOUNG COCONUT JUICE", ["FROZEN"]),
    ("DFZ STICKY RICE BALL", ["DFZ"]),
    ("HB BOBA MILK TEA (TARO)", ["HB"]),
    ("DRAGON FRUIT JELLY", []),                          # whole words only
    ("D FIZZ SODA", []),
])
def test_codes_in(codes, description, expected):
    assert [c["code"] for c in d.codes_in(description, codes)] == expected


def _client(reply: dict):
    """A stand-in for the model client: every call returns `reply` as JSON text."""
    def create(**_):
        return SimpleNamespace(content=[SimpleNamespace(text=json.dumps(reply))], stop_reason="end_turn")
    return SimpleNamespace(messages=SimpleNamespace(create=create))


def _draft(codes, description, reply):
    row = {"item_no": "1", "promo_description": description}
    row["_codes"] = d.codes_in(description, codes)
    return d.draft_one(_client(reply), "m", "m/v", "system", row)


def test_d_fz_is_dragonfly_and_frozen(codes):
    out = _draft(codes, "D FZ STIR-FRIED EEL",
                 {"brand": None, "product": "stir-fried eel", "pack_format": "other", "is_branded": False,
                  "product_terms": ["eel"], "search_queries": ["chuồn chuồn lươn xào"]})
    assert out["brand"] == "Dragonfly" and out["is_branded"] == "true"
    assert out["pack_format"] == "frozen"
    assert "chuồn chuồn" in out["brand_terms"].split("|")


def test_frozen_item_with_no_brand_keeps_its_search_terms(codes):
    out = _draft(codes, "FZ PURE SUGARCANE JUICE",
                 {"brand": None, "product": "sugarcane juice", "pack_format": "bottle", "is_branded": False,
                  "brand_terms": [], "product_terms": ["sugarcane juice", "nước mía", "甘蔗汁"],
                  "search_queries": ["nước mía đông lạnh", "frozen sugarcane juice", "冷冻甘蔗汁"]})
    assert out["is_branded"] == "false" and out["pack_format"] == "frozen"
    assert out["brand_terms"] is None                        # no brand to match
    assert out["product_terms"] == "sugarcane juice|nước mía|甘蔗汁"
    assert out["search_queries"].split("|") == ["nước mía đông lạnh", "frozen sugarcane juice", "冷冻甘蔗汁"]


def test_unbranded_item_that_is_not_frozen_has_no_terms(codes):
    out = _draft(codes, "BAMBOO TRAY (20/25/30/35)",
                 {"brand": None, "product": "bamboo tray", "pack_format": "other", "is_branded": False,
                  "product_terms": ["bamboo tray"], "search_queries": ["bamboo tray"]})
    assert out["product_terms"] is None and out["search_queries"] is None


def test_version_changes_with_the_code_list(codes):
    assert d.terms_version("m", codes) != d.terms_version("m", codes[:-1])
