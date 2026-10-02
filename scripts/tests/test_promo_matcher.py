"""The keyword matcher and judge plumbing in scripts/promo_common.py.

Every case here is a real failure mode met while building the October run — see
the comments. Run:  python -m pytest scripts/tests
"""

import sys
import unicodedata
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest  # noqa: E402

from promo_common import ItemTerms, final_status, judge_majority, match_text, split_terms  # noqa: E402


def level(terms, text):
    return terms.classify(match_text(text))


# ── whole words, accents, scripts ────────────────────────────────────────────

def test_single_vietnamese_word_never_folds_accents():
    # "cam" (orange) must not match "cảm ơn" (thank you)
    t = ItemTerms("fanta", "fanta", "cam")
    assert level(t, "Fanta cảm ơn mọi người")["keyword_level"] == "close"
    assert level(t, "Fanta vị cam ngon")["keyword_level"] == "exact"


def test_multi_word_unaccented_term_matches_accented_text():
    t = ItemTerms("chuon chuon", "bánh tráng")
    r = level(t, "Bánh tráng Chuồn Chuồn ngon")
    assert r["keyword_level"] == "exact" and r["brand_hit"] == "chuon chuon"


def test_decomposed_vietnamese_still_matches():
    # Mentionlytics stores some Vietnamese in NFD; the October Exact Cozy post is spelled "Cosy"
    text = unicodedata.normalize("NFD", "Trà Vải Cosy, nhanh, tiện ngon #travaicozy")
    assert level(ItemTerms("cozy|cosy", "trà", "vải"), text)["keyword_level"] == "exact"


def test_whole_word_only_for_latin():
    assert level(ItemTerms("cozy", "tea"), "#cozytea time with tea")["keyword_level"] is None
    assert level(ItemTerms("sting", "energy drink"), "stingray energy drink")["keyword_level"] is None


def test_thai_matches_as_substring():
    t = ItemTerms("ดีโด้", "น้ำส้ม", "สายน้ำผึ้ง")
    assert level(t, "#ดีโด้น้ำส้มสายน้ำผึ้ง อร่อย")["keyword_level"] == "exact"


def test_thai_sara_am_spellings_compare_equal():
    # "นํ้า" (nikhahit + mai tho) is how the October Fanta Orange video spells น้ำ
    t = ItemTerms("แฟนต้า", "แฟนต้า", "น้ำส้ม")
    assert level(t, "แฟนต้านํ้าส้มกับนํ้าเบอร์รี่")["keyword_level"] == "exact"


def test_negative_term_drops_the_candidate():
    t = ItemTerms("hoshi", "gummy", "mango", "#seventeen")
    assert level(t, "hoshi mango gummy #seventeen")["keyword_level"] is None


def test_flavor_only_required_when_item_has_one():
    assert level(ItemTerms("oragon", "chili garlic oil"), "Oragon chili garlic oil!")["keyword_level"] == "exact"
    assert level(ItemTerms("bento", "squid", "spicy"), "Bento squid snack")["keyword_level"] == "close"


def test_every_hit_is_a_substring_of_match_text():
    # tests/assert_promo_exact_has_terms.sql re-checks hits with instr(match_text, hit)
    cases = [(ItemTerms("chuon chuon", "bánh tráng"), "BÁNH TRÁNG Chuồn Chuồn"),
             (ItemTerms("ดีโด้", "น้ำส้ม", "สายน้ำผึ้ง"), "ดีโด้ น้ำส้มสายน้ำผึ้ง"),
             (ItemTerms("cozy|cosy", "trà", "vải"), "Trà Vải Cosy")]
    for t, text in cases:
        mt, r = match_text(text), t.classify(match_text(text))
        for hit in (r["brand_hit"], r["product_hit"], r["flavor_hit"]):
            if hit:
                assert hit in mt


def test_split_terms_dedupes_and_trims():
    assert split_terms(" a | B|b ||nan| c ") == ["a", "B", "c"]
    assert split_terms(None) == []


# ── keyword level x judge ────────────────────────────────────────────────────

@pytest.mark.parametrize("kw, verdict, expected", [
    ("exact", "exact", "Exact"),
    ("close", "exact", "Close"),     # the judge can never raise a level
    ("exact", "close", "Close"),
    ("exact", "reject", None),
    ("close", "garbage", None),
])
def test_final_status(kw, verdict, expected):
    assert final_status(kw, verdict) == expected


class _FakeResp:
    def __init__(self, text):
        self.content = [type("B", (), {"text": text})()]
        self.stop_reason = "end_turn"


class _FakeClient:
    """Replays canned replies, one per call."""

    def __init__(self, replies):
        self._replies = list(replies)
        self.messages = self

    def create(self, **_):
        return _FakeResp(self._replies.pop(0))


def _reply(verdict):
    return f'{{"reason": "r-{verdict}", "matched_content_item": "x", "verdict": "{verdict}"}}'


def test_majority_vote_keeps_the_majority():
    c = _FakeClient([_reply("close"), _reply("reject"), _reply("close")])
    r = judge_majority(c, "m", {}, {"text": "t"}, {}, votes=3)
    assert r["verdict"] == "close" and r["votes"] == "close,reject,close" and r["reason"] == "r-close"


def test_three_way_split_is_a_reject():
    c = _FakeClient([_reply("exact"), _reply("close"), _reply("reject")])
    assert judge_majority(c, "m", {}, {"text": "t"}, {}, votes=3)["verdict"] == "reject"


def test_unparseable_votes_leave_the_pair_unjudged():
    # each judge() call retries once, so 3 votes x 2 attempts of garbage
    c = _FakeClient(["no json"] * 6)
    assert judge_majority(c, "m", {}, {"text": "t"}, {}, votes=3) is None
