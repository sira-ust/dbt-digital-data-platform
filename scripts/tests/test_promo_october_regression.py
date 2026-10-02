"""October 2026 regression: the pipeline must reproduce the hand-built workbook.

Runs against the LOCAL mart built on the REAL Databricks snapshot:
    python scripts/pull_real_snapshot.py
    ... the local run in models/docs/_promo_social.md, with local_data_root = data/real ...
    python -m pytest scripts/tests/test_promo_october_regression.py
Skipped when dev.duckdb has no October mart or holds only mock social data — so it
never fails a laptop that has not pulled the snapshot.

Expectations are the spec's, from the October workbook. TikTok-only October rows
(Cozy Matcha Genmaicha, Oragon) are not expected here: TikTok is the manual step.
"""

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
DB = ROOT / "dev.duckdb"
MONTH = "2026-10-01"


@pytest.fixture(scope="module")
def mart():
    duckdb = pytest.importorskip("duckdb")
    if not DB.exists():
        pytest.skip("no dev.duckdb")
    con = duckdb.connect(str(DB), read_only=True)
    try:
        n_posts = con.sql("select count(*) from ust_staging.stg_mentionlytics__mentions").fetchone()[0]
        rows = con.sql(f"""select item_no, match_status, source
                           from ust_reporting.mart_promo_social_match
                           where promo_month = date '{MONTH}'""").fetchall()
    except Exception as e:
        pytest.skip(f"October mart not built: {e}")
    finally:
        con.close()
    if not rows or n_posts < 40_000:
        pytest.skip("mart not built on the real social listening snapshot")
    out = {}
    for item_no, status, source in rows:
        out.setdefault(item_no, set()).add((status, source))
    return out


def test_every_promo_item_present(mart):
    assert len(mart) == 52


def test_deedo_sainamphueng_exact_from_social_listening(mart):
    assert mart["34585"] == {("Exact", "Social Listening")}


@pytest.mark.parametrize("item_no", ["34590", "34592",                 # Deedo yogurt juices
                                     "37350", "37351", "37352", "37353",  # Bento squid flavors
                                     "43220"])                           # Chuồn Chuồn rice paper
def test_close_from_social_listening(mart, item_no):
    assert mart[item_no] == {("Close", "Social Listening")}


@pytest.mark.parametrize("item_no", ["22247",                              # Tean's crispy garlic chili
                                     "34637",                              # Sting Red
                                     "34662", "34658",                     # Fanta Grape / Orange
                                     "34420", "34421", "34422", "34423", "34424"])  # Cozy teas
def test_scraped(mart, item_no):
    assert mart[item_no] == {("Exact", "Scraped")}


@pytest.mark.parametrize("item_no", ["86251", "73143", "55027", "71335", "73230"])
def test_unbranded_items_stay_unmatched(mart, item_no):
    assert mart[item_no] == {("Unmatched", None)}
