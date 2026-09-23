"""Generate mock parquet for local DuckDB dev — no Unity Catalog access needed.

Reads data/uc_schema_snapshot.csv (produced once by scripts/snapshot_uc_schema.py)
and emits one parquet per table into data/mock/ (git-ignored), mirroring the
real Unity Catalog schemas under ust_databricks:

  data/mock/jdawmsrep/<table>.parquet  all 16 jdawmsrep tables (WMS replica)
  data/mock/navrep/<table>.parquet     NAV ERP replica — generic filler, and only
                                       once navrep appears in the snapshot
  data/mock/mysql/<table>.parquet      ust_admin_users, ust_category
                                       (the two mysql tables with no JSON sample)

The mock rows are constraint-aware so the existing YAML tests pass on DuckDB:
unique PKs, valid FK chains (invlod->invsub->invdtl, shipment->shipment_line,
pckwrk_hdr->pckwrk_dtl), unique_combination_of_columns grains, and recent
loaddate values. Columns without constraints get type-correct filler.

admin_users mocks reuse the usernames found in the local user-activity sample
so the int-layer enrichment joins produce hits; ust_category reuses
seeds/seed_categories.csv ids/names so category decoding lines up.

Deterministic: seeded RNG; timestamps are anchored to "now" at generation time.

Run from the repo root:  python scripts/generate_jdawms_mock.py
"""

import csv
import hashlib
import json
import random
import re
from datetime import datetime, timedelta
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SNAPSHOT = ROOT / "data" / "uc_schema_snapshot.csv"
DICTIONARY = ROOT / "seeds" / "seed_jdawms_data_dictionary.csv"
OUT_JDAWMS = ROOT / "data" / "mock" / "jdawmsrep"
OUT_NAV = ROOT / "data" / "mock" / "navrep"
OUT_MYSQL = ROOT / "data" / "mock" / "mysql"

# navrep (NAV ERP): keys and FK chains ARE declared now — see the navrep KEYED
# block below. Everything not named there is still type-correct filler. Add a
# KEYED entry before giving a nav staging model a unique/relationship test, or
# the test will fail on random collisions rather than on anything real.
NAV_DEFAULT_ROWS = 200

# ---------------------------------------------------------------------------
# mine literal enumerated codes straight out of the SME dictionary comments,
# e.g. "One of: Full (F), Partial (P)..." or "L = Pallet pick, S = case pick"
# so mock values for coded columns (locsts, lodlvl, attr_str1_flg's sibling
# attr_str1, dte_code, ...) are real WMS codes, not generic filler.
# ---------------------------------------------------------------------------
_EQ_PAT = re.compile(r"['\"]?([A-Z][A-Za-z0-9]{0,4})['\"]?\s*=\s*[A-Za-z][A-Za-z0-9 /,-]{2,40}?(?:[.,;]|\s{2}|$)")
_PAREN_PAT = re.compile(r"[A-Za-z][A-Za-z /-]{2,30}?\(([A-Z][A-Za-z0-9]{0,4})\)")


def extract_enum_codes() -> dict[tuple[str, str], list[str]]:
    codes: dict[tuple[str, str], list[str]] = {}
    for r in csv.DictReader(open(DICTIONARY, encoding="utf-8")):
        comment = r["column_comment"]
        if not comment:
            continue
        found = _EQ_PAT.findall(comment) or _PAREN_PAT.findall(comment)
        # dedupe, keep order; require 2+ distinct codes to count as a real enum
        seen = list(dict.fromkeys(found))
        if len(seen) >= 2:
            codes[(r["table_name"], r["column_name"])] = seen
    return codes


ENUM_CODES = extract_enum_codes()

rng = random.Random(42)
NOW = datetime.now().replace(microsecond=0)

# ---------------------------------------------------------------------------
# entity pools (shared across tables so FKs and joins line up)
# ---------------------------------------------------------------------------
WH = "WMD1"
CLIENT = "----"
PARTS = [f"PRT{i:05d}" for i in range(1, 51)]
LOCS = [f"{a}{b:02d}-{c:02d}-{d:02d}" for a in "AB" for b in range(1, 6) for c in range(1, 5) for d in range(1, 6)]
LOADS = [f"LOD{i:07d}" for i in range(1, 301)]
SUBS = [f"SUB{i:07d}" for i in range(1, 601)]
DTLS = [f"DTL{i:07d}" for i in range(1, 901)]
WRKREFS = [f"WRK{i:06d}" for i in range(1, 201)]
SHIP_IDS = [f"SID{i:07d}" for i in range(1, 101)]
ORD_NUMS = [f"ORD{i:07d}" for i in range(1, 151)]
USERS = ["WMSUSER1", "WMSUSER2", "WMSUSER3", "RFOP01", "RFOP02"]
FTPCODS = ["CS12", "CS24", "EA01"]
UOMS = ["EA", "CS", "PL"]
INVSTS = ["A", "H", "D"]
DEVCODS = ["PRINTER1", "PRINTER2", "RF01"]
ARECODS = ["RCV", "STG", "PCK", "RSV", "SHP"]
OPRCODS = ["RCV", "PCK", "PUT", "MOV", "ADJ"]


def ts(days_back: float = 60.0) -> datetime:
    """Random timestamp within the past `days_back` days."""
    return NOW - timedelta(seconds=rng.uniform(0, days_back * 86400))


def loaddate() -> datetime:
    """Ingestion watermark — within the past 6 hours (keeps freshness happy)."""
    return NOW - timedelta(seconds=rng.uniform(0, 6 * 3600))


# ---------------------------------------------------------------------------
# name/type-based generic filler (used when no table-specific rule applies)
# ---------------------------------------------------------------------------
# ── NAV boolean columns ────────────────────────────────────────────────────
# NAV stores these as tinyint 0/1, but the DLT pipeline lands them as `int`,
# so the snapshot cannot tell them apart from a real integer and the dtype
# fallback below filled them with randint(0, 99).
#
# That was quietly gutting dev. `blocked = 0` is what makes an item sellable,
# and at 1-in-100 odds only 3 of 200 items were; `in_active = 0` is what makes
# a customer active, so 196 of 200 customers read as INACTIVE. Every mart that
# filters on either returned almost nothing, and the tests passed on the
# handful of rows that survived. mart_account_item_opportunities came out
# completely empty and nothing in the build said so.
#
# Probabilities, not coin flips, so dev looks roughly like production: the
# 48% inactive rate is the measured figure quoted in stg_nav__customers, the
# rest are plausible rather than measured.
NAV_BOOLEANS = {
    "blocked": 0.05,               # 0 = sellable, so this must usually be 0
    "in_active": 0.48,             # 3,485 of 7,198 customers, per stg_nav__customers
    "new_item": 0.10,
    "popular_item": 0.15,
    "show_on_web": 0.70,
    "released": 0.80,              # promotion_line: released AND NOT discontinued
    "discontinued": 0.10,          #   is the live-promo gate
    "new_on_promotion": 0.25,
    "appointment_required": 0.15,
    "is_frozen_item": 0.20,
    "selected": 0.60,
    "m2_customer": 0.50,
    "m2_order": 0.50,
}


def _nav_bool(col: str) -> int:
    return 1 if rng.random() < NAV_BOOLEANS[col] else 0


NAME_RULES = [  # (predicate on column name, value factory taking row index)
    (lambda c: c == "loaddate", lambda i: loaddate()),
    (lambda c: c == "_rescued_data", lambda i: None),
    (lambda c: c in ("wh_id", "wh_id_tmpl"), lambda i: WH),
    (lambda c: c in ("prt_client_id", "client_id", "host_client_id"), lambda i: CLIENT),
    (lambda c: c == "prtnum", lambda i: rng.choice(PARTS)),
    (lambda c: c in ("stoloc", "frstol", "tostol", "srcloc", "dstloc", "refloc", "stgloc"), lambda i: rng.choice(LOCS)),
    (lambda c: c in ("lodnum", "to_lodnum"), lambda i: rng.choice(LOADS)),
    (lambda c: c in ("subnum", "to_subnum"), lambda i: rng.choice(SUBS)),
    (lambda c: c in ("dtlnum", "to_dtlnum"), lambda i: rng.choice(DTLS)),
    (lambda c: c == "wrkref", lambda i: rng.choice(WRKREFS)),
    (lambda c: c == "ship_id", lambda i: rng.choice(SHIP_IDS)),
    (lambda c: c == "ordnum", lambda i: rng.choice(ORD_NUMS)),
    (lambda c: c in ("invsts", "frinvs", "toinvs", "invsts_prg"), lambda i: rng.choice(INVSTS)),
    (lambda c: c == "ftpcod", lambda i: rng.choice(FTPCODS)),
    (lambda c: c == "uomcod", lambda i: rng.choice(UOMS)),
    (lambda c: c in ("devcod", "ackdevcod"), lambda i: rng.choice(DEVCODS)),
    (lambda c: c in ("arecod", "fr_arecod", "to_arecod", "srcare"), lambda i: rng.choice(ARECODS)),
    (lambda c: c == "oprcod", lambda i: rng.choice(OPRCODS)),
    (lambda c: c.endswith(("usr_id", "user_id")) or c == "usr_id", lambda i: rng.choice(USERS)),
    (lambda c: "qty" in c, lambda i: rng.randint(0, 500)),
    (lambda c: c.endswith("_flg") or c.startswith("is_"), lambda i: rng.randint(0, 1)),
]


def generic_value(table: str, col: str, dtype: str, i: int):
    codes = ENUM_CODES.get((table, col))
    if codes:
        return rng.choice(codes)
    # NAV 0/1 flags land as `int`, so they must be caught by NAME before the
    # dtype fallback turns them into randint(0, 99) — see NAV_BOOLEANS.
    if col in NAV_BOOLEANS:
        return _nav_bool(col)
    if col.endswith("_deliveries"):
        return rng.randint(0, 1)
    for pred, factory in NAME_RULES:
        if pred(col):
            v = factory(i)
            # respect the landed type: qty rules etc. may hit string columns
            if v is not None and dtype == "string" and not isinstance(v, str):
                v = str(v)
            return v
    if dtype == "timestamp":
        return ts()
    if dtype in ("int", "bigint"):
        return rng.randint(0, 99)
    if dtype.startswith("decimal"):
        return round(rng.uniform(0, 1000), 3)
    return f"{col[:16]}_{i % 23}"  # generic short string


# ---------------------------------------------------------------------------
# table-specific rules: PKs, FKs, unique-combination grains
# ---------------------------------------------------------------------------
def combos(pools: list[list], n: int) -> list[tuple]:
    """n distinct tuples sampled from the cartesian product of pools."""
    seen: set[tuple] = set()
    while len(seen) < n:
        seen.add(tuple(rng.choice(p) for p in pools))
    return sorted(seen)


ROWCOUNTS = {
    "dlytrn": 1000, "inv_snap": 200, "invdtl": len(DTLS), "invlod": len(LOADS),
    "invsub": len(SUBS), "invsum": 400, "locmst": len(LOCS), "pckwrk_dtl": 400,
    "pckwrk_hdr": len(WRKREFS), "prtdsc": 0, "prtftp": 0, "prtftp_dtl": 0,
    "prtmst": len(PARTS), "rplcfg": 50, "shipment": len(SHIP_IDS), "shipment_line": 400,
}

# precomputed key/context columns per table: {table: {col: [values...]}}
KEYED: dict[str, dict[str, list]] = {}

KEYED["dlytrn"] = {"dlytrn_id": [str(1000000 + i) for i in range(ROWCOUNTS["dlytrn"])]}
KEYED["inv_snap"] = {"inv_snap_id": [str(2000000 + i) for i in range(ROWCOUNTS["inv_snap"])]}
KEYED["invlod"] = {"lodnum": list(LOADS)}
KEYED["invsub"] = {"subnum": list(SUBS), "lodnum": [rng.choice(LOADS) for _ in SUBS]}
KEYED["invdtl"] = {"dtlnum": list(DTLS), "subnum": [rng.choice(SUBS) for _ in DTLS]}

_invsum = combos([[WH], LOCS, PARTS, [CLIENT], INVSTS], ROWCOUNTS["invsum"])
KEYED["invsum"] = {k: [c[j] for c in _invsum] for j, k in enumerate(["wh_id", "stoloc", "prtnum", "prt_client_id", "invsts"])}

KEYED["locmst"] = {"wh_id": [WH] * len(LOCS), "stoloc": list(LOCS)}
KEYED["pckwrk_hdr"] = {"wrkref": list(WRKREFS)}
KEYED["pckwrk_dtl"] = {
    "wrkref_dtl": [f"WRKD{i:07d}" for i in range(ROWCOUNTS["pckwrk_dtl"])],
    "wrkref": [rng.choice(WRKREFS) for _ in range(ROWCOUNTS["pckwrk_dtl"])],
}

_prtdsc = [("prtfam", f"FAM{i}", "en_US") for i in range(10)] + [("invsts", s, "en_US") for s in INVSTS]
KEYED["prtdsc"] = {k: [c[j] for c in _prtdsc] for j, k in enumerate(["colnam", "colval", "locale_id"])}
ROWCOUNTS["prtdsc"] = len(_prtdsc)

_prtftp = combos([PARTS, FTPCODS, [CLIENT], [WH]], 60)
KEYED["prtftp"] = {k: [c[j] for c in _prtftp] for j, k in enumerate(["prtnum", "ftpcod", "prt_client_id", "wh_id"])}
ROWCOUNTS["prtftp"] = len(_prtftp)

_prtftp_dtl = [(p, f, c, w, UOMS[lvl - 1], lvl) for (p, f, c, w) in _prtftp for lvl in (1, 2)]
KEYED["prtftp_dtl"] = {k: [c[j] for c in _prtftp_dtl] for j, k in enumerate(["prtnum", "ftpcod", "prt_client_id", "wh_id", "uomcod", "uomlvl"])}
ROWCOUNTS["prtftp_dtl"] = len(_prtftp_dtl)

KEYED["prtmst"] = {"prtnum": list(PARTS), "prt_client_id": [CLIENT] * len(PARTS), "wh_id_tmpl": [WH] * len(PARTS)}
KEYED["rplcfg"] = {"rplnum": [str(3000 + i) for i in range(ROWCOUNTS["rplcfg"])]}
KEYED["shipment"] = {"ship_id": list(SHIP_IDS)}
KEYED["shipment_line"] = {
    "ship_line_id": [str(4000000 + i) for i in range(ROWCOUNTS["shipment_line"])],
    "ship_id": [rng.choice(SHIP_IDS) for _ in range(ROWCOUNTS["shipment_line"])],
}


# ── navrep (NAV ERP) keys and FK chains ────────────────────────────────────
# Added when the first nav staging model grew a `unique` test
# (stg_nav__customers.customer_key). Until then navrep was pure filler, per the
# note at the top of this file — and that had a sharper edge than a failing
# test. A refreshed snapshot produced 23 distinct customer_no across 200 rows,
# which not only broke the test but collapsed the join in
# stg_nav__customer_locations from 200 keys to 23, quietly gutting dev coverage
# of the whole presence chain. Keys here, FKs below, so a nav model that joins
# in dev actually gets rows instead of passing its tests vacuously.
#
# customer_geocode.parquet is written by scripts/geocode_customers.py FROM
# customer.parquet, so it inherits whatever keys this produces — re-run that
# script (local mode, no credentials, no cost) after changing NAV_CUSTOMERS.
# ── NAV's blank date, and the quirks measured in the real source ───────────
# NAV writes an UNSET date as 1753-01-01 (SQL Server's datetime minimum), not
# NULL, and that sentinel survives ingestion intact — verified in
# ust_databricks.navrep on 2026-09-23. Staging is where it becomes NULL; the
# mock has to emit it so that conversion is actually exercised.
NAV_BLANK_DATE = datetime(1753, 1, 1)

# The distributions below are MEASURED from the live NAV source on 2026-09-23,
# not invented. Reproducing the real data's defects is the point: a mock where
# every flag is tidily populated tests nothing that production will throw.
#   focus_item        5 of 7,573 items, and 4 of those carry a 2017 window
#   new_item        357 of 7,573, ALL with a blank New End date -> never "live"
#   sprice          361 of 12,967 promo lines, and 0 of the 86 live today
#   promo buy/free   27 of the 86 live lines
#   store type    ~1,750 assignments across 3,742 active customers (~half)
#   budgeted_amount  zero on all 7,242 customers -- the field is not maintained


def _nav_date_or_blank(value, p_set: float):
    """A real date with probability p_set, NAV's blank sentinel otherwise."""
    return value if rng.random() < p_set else NAV_BLANK_DATE


NAV_CUSTOMERS = [f"C{i:05d}" for i in range(NAV_DEFAULT_ROWS)]
NAV_ITEMS = [f"ITM{i:05d}" for i in range(NAV_DEFAULT_ROWS)]
NAV_INVOICES = [f"INV{i:06d}" for i in range(NAV_DEFAULT_ROWS)]
NAV_CRMEMOS = [f"CRM{i:06d}" for i in range(NAV_DEFAULT_ROWS)]
# the real territory codes the event-log mock also uses, so a rep who has app
# activity in dev also has NAV invoices to join to
NAV_REPS = ["002", "003", "004", "007", "008", "009", "015", "018",
            "019", "024", "025", "026", "030", "031", "032"]

# store type: about half of accounts carry one, a handful carry two, and the
# rest carry none — matching the real spread, because "no type" is the case the
# recommendation mart has to handle and it covers half the book.
_types = []
for _ in NAV_CUSTOMERS:
    roll = rng.random()
    if roll < 0.45:
        _types.append(rng.choice([(1, 0, 0), (0, 1, 0), (0, 0, 1)]))
    elif roll < 0.47:
        _types.append(rng.choice([(1, 1, 0), (1, 0, 1), (0, 1, 1)]))
    else:
        _types.append((0, 0, 0))

KEYED["customer"] = {
    "customer_no": list(NAV_CUSTOMERS),
    "salesperson_code": [rng.choice(NAV_REPS) for _ in NAV_CUSTOMERS],
    "customer_retail":       [t[0] for t in _types],
    "customer_wholesale":    [t[1] for t in _types],
    "customer_food_service": [t[2] for t in _types],
    # ZERO ON EVERY ROW, because that is what NAV holds. Kept rather than
    # dropped so anything that mistakes it for a store target fails in dev.
    "budgeted_amount": [0.0 for _ in NAV_CUSTOMERS],
}
# item lifecycle. The focus and new WINDOWS are deliberately broken the way NAV's
# are: focus dates sit in 2017, and new_end_date is blank on every flagged item,
# so nothing can ever be "live now" by its own window. Any model that gates on
# those windows must show zero in dev, which is the honest signal.
_focus = [1 if i < 5 else 0 for i in range(NAV_DEFAULT_ROWS)]
_new = [1 if rng.random() < 0.047 else 0 for _ in range(NAV_DEFAULT_ROWS)]
KEYED["item"] = {
    "item_no": list(NAV_ITEMS),
    "unit_price": [round(rng.uniform(3, 400), 2) for _ in NAV_ITEMS],
    "discontinued": [1 if rng.random() < 0.30 else 0 for _ in NAV_ITEMS],
    "focus_item": _focus,
    # 2017 windows on the flagged ones, blank on the rest — stale, as in NAV
    "focus_begin_date": [datetime(2017, 7, 1) if f and rng.random() < 0.8
                         else NAV_BLANK_DATE for f in _focus],
    "focus_end_date": [datetime(2017, 7, 31) if f and rng.random() < 0.8
                       else NAV_BLANK_DATE for f in _focus],
    "new_item": _new,
    "new_begin_date": [_nav_date_or_blank(NOW - timedelta(days=rng.randint(10, 300)), 0.06)
                       if n else NAV_BLANK_DATE for n in _new],
    # ALWAYS BLANK. 357 of 357 in NAV, which is why new_live_now is zero there.
    "new_end_date": [NAV_BLANK_DATE for _ in NAV_ITEMS],
}
KEYED["ethnicity_codes"] = {
    "ethnicity_code": [f"ETH{i:03d}" for i in range(NAV_DEFAULT_ROWS)]
}
KEYED["customer_ethnicity"] = {
    "customer_no": [rng.choice(NAV_CUSTOMERS) for _ in range(NAV_DEFAULT_ROWS)]
}

# ── posted sales: a PURCHASE HISTORY, not random pairs ─────────────────────
# The rest of this file only has to satisfy keys and FK chains, because that is
# all the tests ask of it. These three tables are different: the marts built on
# them (int_customer_item_cadence, mart_account_item_history,
# mart_account_item_opportunities) measure HOW OFTEN an account buys an item,
# and a random customer x item per line makes every pair unique. Every test
# then passes vacuously — 200 lines produced 200 pairs, each bought exactly
# once, so no reorder rhythm existed, reorder_status was 'rhythm unknown' on
# every row, and the opportunities mart came out EMPTY. Nothing was wrong with
# the SQL; there was simply nothing in the data to find.
#
# So this block generates buying RELATIONSHIPS — an account, an item, and a
# cadence — and then plays them forward over ~14 months. That gives dev:
#   - repeat purchases, so a median gap exists and cadence is computable
#   - deliberately lapsed relationships, so 'stopped buying' fires
#   - items shared across accounts in a group, so 'peers buy it' fires
#   - dates spread over 420 days, not the 60 that ts() defaults to
#
# It is still synthetic. It proves the models RUN and that their branches are
# reachable; it proves nothing about the real distribution.
NAV_HISTORY_DAYS = 420          # how far back posted history reaches
NAV_ACTIVE_CUSTOMERS = 60       # of NAV_DEFAULT_ROWS, the ones that buy at all
NAV_CADENCE_CHOICES = [7, 14, 21, 30, 45, 60, 90]
NAV_UOMS = ["CASE", "EA", "PALLET"]

# VALUE COVERAGE IS PARTIAL, AND THAT IS ON PURPOSE. ADF only began exporting
# Amount / Line Amount / Unit Price on 2026-09-20, and the blob's historical
# seed file still carries the old column list — so in PRODUCTION every invoice
# line older than that has a NULL amount and always will, unless the seed is
# re-exported. 19,654,620 of 19,696,349 rows, measured 2026-09-23.
#
# Dev mirrors that shape so the NULL path is actually exercised, but over a
# WIDER window than production has: 90 days rather than 3, so the value-based
# aggregates have enough rows to be worth looking at. Do not read the dev ratio
# as an estimate of the real one.
NAV_VALUE_FROM_DAYS = 90

# A CORE ITEM SET the active customers draw most of their purchases from, so
# the same item recurs across accounts. Without this every account buys from
# the full 200-item catalogue and no two accounts overlap, which starves the
# peer-based 'peers buy it' reason exactly the way random pairing starves
# cadence.
_core_items = NAV_ITEMS[:40]

_purchases: list[dict] = []     # one entry per customer-item-day
for _cust in NAV_CUSTOMERS[:NAV_ACTIVE_CUSTOMERS]:
    _rep = rng.choice(NAV_REPS)
    _basket = rng.sample(_core_items, rng.randint(3, 8))
    for _item in _basket:
        _cadence = rng.choice(NAV_CADENCE_CHOICES)
        _uom = rng.choice(NAV_UOMS)
        # where this relationship stops. Most run to today; ~1 in 5 stops early
        # enough to read as lapsed (past 2x its own cadence), which is what
        # gives 'stopped buying' something to find.
        _stop = 0 if rng.random() > 0.2 else rng.randint(2, 6) * _cadence
        _day = NAV_HISTORY_DAYS
        while _day > _stop:
            _purchases.append({
                "customer": _cust,
                "item": _item,
                "rep": _rep,
                "days_ago": _day,
                "uom": _uom,
                # ZERO IS A REAL QUANTITY. 2,490,061 invoice lines in NAV
                # carry quantity = 0 -- invoiced, nothing shipped, because the
                # line was cut or went out of stock. The mock emitted only
                # positive quantities, so a test asserting "every item-day sold
                # or returned something" passed locally and failed on 2,440,702
                # production rows. ~13% here matches the measured share.
                "qty": 0 if rng.random() < 0.13 else rng.randint(1, 24),
            })
            # jitter, so gaps vary around the cadence instead of being exact —
            # a perfectly regular series makes median == every gap and hides
            # any bug in the gap arithmetic
            _day -= max(1, int(_cadence * rng.uniform(0.8, 1.2)))

# group a customer's same-day purchases onto ONE invoice, which is the grain
# the replica actually has — several items per document, not one line each
_by_doc: dict[tuple[str, int], list[dict]] = {}
for _p in _purchases:
    _by_doc.setdefault((_p["customer"], _p["days_ago"]), []).append(_p)

def _hdr_channel(days_ago: int) -> dict:
    """pda_order_no / m2_order_no — the posted-sales channel split.

    Same coverage window as the amounts: ADF started exporting these on the
    same day, so an older invoice cannot say which channel it came through.
    """
    if days_ago > NAV_VALUE_FROM_DAYS:
        return {"pda_order_no": None, "m2_order_no": None}
    roll = rng.random()
    if roll < 0.55:
        return {"pda_order_no": f"PDA{rng.randint(100000, 999999)}",
                "m2_order_no": None}
    if roll < 0.80:
        return {"pda_order_no": None,
                "m2_order_no": f"M{rng.randint(100000000, 999999999)}"}
    return {"pda_order_no": None, "m2_order_no": None}   # keyed direct in NAV


def _line_value(qty: int, days_ago: int) -> dict:
    """Amount / line amount / unit price — NULL outside the coverage window.

    Returning None (not 0.0) is the point: a line with no exported amount has
    NO value, and a zero would quietly average into every dollar figure built
    on top as though the sale had been free.
    """
    if days_ago > NAV_VALUE_FROM_DAYS:
        return {"unit_price": None, "line_amount": None, "amount": None}
    unit = round(rng.uniform(4, 180), 2)
    line = round(unit * qty, 2)
    return {"unit_price": unit,
            "line_amount": line,
            # `amount` is net of line discount, so it sits at or below
            # line_amount — the relationship the models assume
            "amount": round(line * rng.uniform(0.85, 1.0), 2)}


_inv_hdr: list[dict] = []
_inv_lin: list[dict] = []
for _i, ((_cust, _days_ago), _lines) in enumerate(sorted(_by_doc.items())):
    _doc = f"INV{_i:06d}"
    _posted = NOW - timedelta(days=_days_ago)
    _inv_hdr.append({
        "document_no": _doc,
        "bill_to_customer_no": _cust,
        "salesperson_code": _lines[0]["rep"],
        "posting_date": _posted,
        "order_date": _posted - timedelta(days=rng.randint(1, 5)),
        # terms are usually net-30 here; a handful run longer so "past terms"
        # has more than one bucket to sort into
        "due_date": _posted + timedelta(days=rng.choice([15, 30, 30, 30, 45, 60])),
        # CHANNEL ON POSTED SALES. Only one of the two is ever set — an order
        # reached us through the PDA or through the website, not both — and
        # neither is set on an order keyed straight into NAV.
        **_hdr_channel(_days_ago),
    })
    for _n, _l in enumerate(_lines, start=1):
        _inv_lin.append({
            "document_no": _doc,
            "line_no": _n,
            "sell_to_customer_no": _cust,
            "item_no": _l["item"],
            "salesperson_code": _l["rep"],
            "posting_date": _posted,
            "quantity": float(_l["qty"]),
            "unit_of_measure": _l["uom"],
            # UOM CODE + CONVERSION, the pair that makes quantities comparable.
            # The code mirrors the free-text uom; the factor is what a CASE or a
            # PALLET is worth in base units.
            "unit_of_measure_code": _l["uom"],
            "qty_per_unit_of_measure": {"EA": 1.0, "CASE": 12.0,
                                        "PALLET": 480.0}[_l["uom"]],
            **_line_value(_l["qty"], _l["days_ago"]),
        })

# credit memos against ~4% of invoice lines, so returns exist and net against
# a real sale rather than against a customer-item pair that never bought
_returns = rng.sample(_inv_lin, max(1, len(_inv_lin) // 25))
_crm_lin: list[dict] = []
for _i, _r in enumerate(_returns):
    _crm_lin.append({
        "document_no": f"CRM{_i:06d}",
        "invoice_no": _r["document_no"],
        "sell_to_customer_no": _r["sell_to_customer_no"],
        "cr_memo_item_no": _r["item_no"],
        "salesperson_code": _r["salesperson_code"],
        # a return posts AFTER the sale it credits — the case that must not
        # reset the account's "last bought" clock
        "posting_date": _r["posting_date"] + timedelta(days=rng.randint(1, 20)),
        "quantity": float(_qty := rng.randint(1, 4)),
        "unit_of_measure": _r["unit_of_measure"],
        "unit_of_measure_code": _r["unit_of_measure"],
        "qty_per_unit_of_measure": _r["qty_per_unit_of_measure"],
        # the credit's own posting date decides coverage, not the sale's
        **_line_value(_qty, _r_days := max(0, (NOW - _r["posting_date"]).days)),
    })

# ── COMMENT AND CHARGE LINES: the empty strings NAV actually writes ────────
# NAV does not write NULL into item_no / sell_to_customer_no -- it writes ''.
# The mock produced neither until 2026-09-23, so a staging filter that tested
# the RAW column for null passed every local test and then failed on Databricks
# against 722,527 rows. Reproducing the blanks is what makes that filter
# testable at all.
#
# Two shapes, because the real table has two:
#   invoice   printed comment lines -- 715,497 of the 722,535 blanks in NAV are
#             literally 'www.ustrading.com/NEW' or '**BROWSE NEW ITEMS ONLINE**'
#             and carry no value
#   credit    CHARGE credits -- CRV, pallet, freight, discount. These DO carry
#             value ($40,344.23 over 10 lines), which is why dropping them has a
#             consequence the invoice side does not have
for _i in range(40):
    _doc = _inv_lin[_i % len(_inv_lin)]["document_no"]
    _inv_lin.append({
        "document_no": _doc,
        "line_no": 900 + _i,
        "sell_to_customer_no": "",
        "item_no": "",
        "salesperson_code": "",
        "posting_date": NOW - timedelta(days=rng.randint(1, 400)),
        "quantity": 0.0,
        "unit_of_measure": "",
        "unit_of_measure_code": "",
        "qty_per_unit_of_measure": None,
        "unit_price": None,
        "line_amount": None,
        "amount": None,
    })

for _i in range(30):
    _crm_lin.append({
        "document_no": f"CRMC{_i:05d}",
        "invoice_no": None,
        "sell_to_customer_no": "" if _i % 5 == 0 else rng.choice(NAV_CUSTOMERS),
        "cr_memo_item_no": "",
        "salesperson_code": rng.choice(NAV_REPS),
        "posting_date": NOW - timedelta(days=rng.randint(1, 120)),
        "quantity": 1.0,
        "unit_of_measure": "",
        "unit_of_measure_code": "",
        "qty_per_unit_of_measure": None,
        "unit_price": round(rng.uniform(20, 900), 2),
        "line_amount": round(rng.uniform(20, 900), 2),
        "amount": round(rng.uniform(20, 900), 2),
    })

ROWCOUNTS["sales_invoice_header"] = len(_inv_hdr)
ROWCOUNTS["sales_invoice_line"] = len(_inv_lin)
ROWCOUNTS["sales_cr_memo_header"] = len(_crm_lin)
ROWCOUNTS["sales_cr_memo_line"] = len(_crm_lin)


def _col(rows: list[dict], key: str) -> list:
    return [r[key] for r in rows]


KEYED["sales_invoice_header"] = {
    k: _col(_inv_hdr, k) for k in
    ("document_no", "bill_to_customer_no", "salesperson_code", "posting_date",
     "order_date", "due_date", "pda_order_no", "m2_order_no")
}
KEYED["sales_invoice_line"] = {
    k: _col(_inv_lin, k) for k in
    ("document_no", "line_no", "sell_to_customer_no", "item_no",
     "salesperson_code", "posting_date", "quantity", "unit_of_measure",
     "unit_of_measure_code", "qty_per_unit_of_measure",
     "unit_price", "line_amount", "amount")
}

KEYED["sales_cr_memo_header"] = {
    "document_no": _col(_crm_lin, "document_no"),
    "bill_to_customer_no": _col(_crm_lin, "sell_to_customer_no"),
    "salesperson_code": _col(_crm_lin, "salesperson_code"),
    "posting_date": _col(_crm_lin, "posting_date"),
    "applies_to_doc_no": _col(_crm_lin, "invoice_no"),
}
# NO line_no: the replica's projection of Sales Cr_Memo Line omits NAV's
# `Line No_`, so this table has no natural key and CANNOT carry a unique test.
# Duplicates on (document_no, item, qty, date) are real distinct lines, not
# ingestion artefacts — 29,004 of 121,290 rows on the live replica.
KEYED["sales_cr_memo_line"] = {
    k: _col(_crm_lin, k) for k in
    ("document_no", "sell_to_customer_no", "cr_memo_item_no", "salesperson_code",
     "posting_date", "quantity", "unit_of_measure", "invoice_no",
     "unit_of_measure_code", "qty_per_unit_of_measure",
     "unit_price", "line_amount", "amount")
}

# promotion_line: without a key here item_no was generic filler ("item_no_7"),
# which joins to nothing in the item master — so dim_items.is_on_promotion was
# false for every item and the 'on promotion' branch of
# mart_account_item_opportunities was unreachable. Windows straddle NOW so some
# promotions are genuinely live today.
_promo_items = rng.sample(NAV_ITEMS, 60)
_promo_begin = [NOW - timedelta(days=rng.randint(1, 120)) for _ in _promo_items]
KEYED["promotion_line"] = {
    "item_no": _promo_items,
    "promotion_code": [f"PROMO{i % 12:03d}" for i in range(len(_promo_items))],
    "promo_code": [f"PC{i % 12:03d}" for i in range(len(_promo_items))],
    "promo_begin_date": _promo_begin,
    # half still running, half already closed
    "promo_end_date": [b + timedelta(days=rng.randint(30, 200)) for b in _promo_begin],
    # SPRICE IS ALMOST ALWAYS ZERO, and zero on every line live today — 0 of 86
    # in NAV. The buy/free mechanic is what is actually maintained (27 of 86),
    # so the pitch list has to lead with that and treat sprice 0 as "not set"
    # rather than as a free item.
    "sprice": [round(rng.uniform(6, 480), 2) if rng.random() < 0.028 else 0.0
               for _ in _promo_items],
    "promo_buy_qty":  [float(rng.randint(2, 12)) if rng.random() < 0.31 else 0.0
                       for _ in _promo_items],
    "promo_free_qty": [float(rng.randint(1, 3)) if rng.random() < 0.31 else 0.0
                       for _ in _promo_items],
}
ROWCOUNTS["promotion_line"] = len(_promo_items)

KEYED["item_ledger_entry"] = {
    "entry_no": list(range(1, NAV_DEFAULT_ROWS + 1)),
    "item_no": [rng.choice(NAV_ITEMS) for _ in range(NAV_DEFAULT_ROWS)],
    "source_no": [rng.choice(NAV_CUSTOMERS) for _ in range(NAV_DEFAULT_ROWS)],
    "salesperson_code": [rng.choice(NAV_REPS) for _ in range(NAV_DEFAULT_ROWS)],
}


def load_snapshot() -> dict[str, dict[str, list[tuple[str, str]]]]:
    schemas: dict[str, dict[str, list[tuple[str, str]]]] = {}
    with open(SNAPSHOT, encoding="utf-8") as f:
        for r in csv.DictReader(f):
            schemas.setdefault(r["table_schema"], {}).setdefault(r["table_name"], []).append(
                (r["column_name"], r["full_data_type"])
            )
    return schemas


def to_frame(table: str, cols: list[tuple[str, str]], n: int, keyed: dict[str, list]) -> pd.DataFrame:
    data = {}
    for col, dtype in cols:
        if col in keyed:
            data[col] = keyed[col][:n]
        else:
            data[col] = [generic_value(table, col, dtype, i) for i in range(n)]
    df = pd.DataFrame(data)
    for col, dtype in cols:  # enforce landed types
        if dtype == "timestamp":
            df[col] = pd.to_datetime(df[col])
        elif dtype in ("int", "bigint"):
            df[col] = df[col].astype("Int64")
        elif dtype.startswith("decimal"):
            df[col] = df[col].astype("float64")
        else:
            df[col] = df[col].astype("string")
    return df


def mock_mysql(schemas) -> None:
    """ust_admin_users (usernames from the local sample) + ust_category (from seed)."""
    OUT_MYSQL.mkdir(parents=True, exist_ok=True)

    sample = ROOT / "data" / "mock" / "mysql" / "raw_api" / "user" / "activity" / "sales_reports.json"
    users: list[str] = []
    if sample.exists():
        d = json.load(open(sample, encoding="utf-8"))
        recs = d["data"]["data"] if isinstance(d, dict) and "data" in d else d
        users = sorted({r.get("user") for r in recs if isinstance(r, dict) and r.get("user")})
    users = users or [f"sales{i}" for i in range(1, 6)]
    users += ["adminuser"]  # one non-salesperson

    keyed = {
        "user_id": [i + 1 for i in range(len(users))],
        "username": users,
        "firstname": [u.capitalize() for u in users],
        "lastname": ["Mock"] * len(users),
        "email": [f"{u}@example.com" for u in users],
        "salesperson_code": [f"S{i:03d}" if u != "adminuser" else "" for i, u in enumerate(users)],
        "is_salesperson": [0 if u == "adminuser" else 1 for u in users],
        "is_active": [1] * len(users),
        "role_name": ["admin" if u == "adminuser" else "salesperson" for u in users],
        "interface_locale": ["en_US"] * len(users),
    }
    df = to_frame("ust_admin_users", schemas["mysql"]["ust_admin_users"], len(users), keyed)
    df.to_parquet(OUT_MYSQL / "ust_admin_users.parquet", index=False)
    print(f"mysql.ust_admin_users: {len(df)} rows ({', '.join(users)})")

    cats = list(csv.DictReader(open(ROOT / "seeds" / "seed_categories.csv", encoding="utf-8")))
    keyed = {
        "category_id": [int(c["category_id"]) for c in cats],
        "parent_id": [0] * len(cats),
        "name": [c["category_name"] for c in cats],
        "is_active": ["1"] * len(cats),
        "level": [1] * len(cats),
        "position": list(range(1, len(cats) + 1)),
    }
    df = to_frame("ust_category", schemas["mysql"]["ust_category"], len(cats), keyed)
    df.to_parquet(OUT_MYSQL / "ust_category.parquet", index=False)
    print(f"mysql.ust_category: {len(df)} rows (from seed_categories)")


def mock_nav(schemas) -> None:
    """navrep (NAV ERP) — generic filler per table; no-op until the schema lands."""
    tables = schemas.get("navrep")
    if not tables:
        print("navrep: not in the snapshot yet, skipped "
              "(re-run scripts/snapshot_uc_schema.py once the ingestion lands it)")
        return

    OUT_NAV.mkdir(parents=True, exist_ok=True)
    for table, cols in sorted(tables.items()):
        n = ROWCOUNTS.get(table, NAV_DEFAULT_ROWS)
        df = to_frame(table, cols, n, KEYED.get(table, {}))
        df.to_parquet(OUT_NAV / f"{table}.parquet", index=False)
        print(f"navrep.{table}: {len(df)} rows, {len(cols)} cols")



def mock_geocode(schemas) -> None:
    """ust_external.nav_customer_geocode — the out-of-band coordinate table.

    Generated HERE rather than by scripts/geocode_customers.py, because that
    script's only job is calling Google: a local run against this mock would
    send 200 fake addresses ("address_0, city_0") for about a dollar and get
    garbage back. A mock needs coordinates, not a geocoder.

    Derived from the customer mock so the keys always agree -- that pairing is
    load-bearing. When customer_no last changed shape underneath a stale
    geocode file, the join in stg_nav__customer_locations fell from 200 keys to
    23 and quietly gutted dev coverage of the entire presence chain.

    THREE POPULATIONS ON PURPOSE, because the models branch on all three:
      ~88% resolve to a real coordinate near the office
      ~12% have NO ROW AT ALL, so dim_customers.has_coordinates is false and
           the "visit history is unknowable" path is actually exercised -- it
           matches the 12% of real customers with no resolvable address
      a few resolve to (0,0), the classic geocoder failure that
           stg_nav__customer_locations filters out by name

    Some coordinates are deliberately placed within ~40 m of each other so the
    shared-geofence case (int_rep_customer_presence.is_ambiguous, 21.2% of real
    customers) is reachable in dev instead of only in production.
    """
    tables = schemas.get("navrep")
    if not tables or "customer" not in tables:
        print("customer_geocode: navrep.customer not in the snapshot, skipped")
        return

    keys = KEYED["customer"]["customer_no"]
    # the office, from dbt_project.yml office_latitude / office_longitude
    lat0, lon0 = 37.6449309, -122.1362259

    rows = []
    for i, key in enumerate(keys):
        if i % 8 == 7:            # ~12%: no geocode row at all
            continue
        if i % 47 == 13:          # a couple of (0,0) geocoder failures
            lat, lon = 0.0, 0.0
            status = "ZERO_RESULTS"
        else:
            # pairs of neighbours land inside one geofence; ~0.0003 deg is ~33 m
            cluster = i // 2
            jitter = 0.0003 if i % 2 else 0.0
            lat = round(lat0 + (cluster % 25) * 0.004 - 0.05 + jitter, 7)
            lon = round(lon0 + (cluster // 25) * 0.006 - 0.02 + jitter, 7)
            status = "OK"
        rows.append({
            "customer_no": key,
            "latitude": lat,
            "longitude": lon,
            "geocode_status": status,
            "geocoded_address": f"{i} Mock St, Hayward, CA 945{i % 100:02d}",
            "address_hash": hashlib.sha256(key.encode()).hexdigest()[:32],
            "geocoded_at": pd.Timestamp("2026-09-01 12:00:00"),
        })

    df = pd.DataFrame(rows)
    OUT_NAV.mkdir(parents=True, exist_ok=True)
    df.to_parquet(OUT_NAV / "customer_geocode.parquet", index=False)
    ok = int((df.geocode_status == "OK").sum())
    print(f"navrep.customer_geocode: {len(df)} rows "
          f"({ok} usable, {len(df) - ok} zero-result, "
          f"{len(keys) - len(df)} customers with no row)")

def mock_event_log() -> None:
    """Order-submit events, so fct_orders is not empty in dev.

    WHY THIS EXISTS. raw_log.json is a 500-record CAPTURE from the dev team and
    stays untouched — it is the only sample of what the real API returns, and
    scripts read usernames out of it. But 401 of its 500 rows are login events
    (family 01) and NOT ONE is an order submit (family 04), so fct_orders built
    to zero rows in dev and everything downstream of it — mart_rep_period_status
    above all — was an empty table that still passed every test. The channel
    split and largest-order columns were written, shipped and never once seen
    running on data.

    So this writes a SECOND file beside the capture and the source globs both.
    Nothing is overwritten and the capture keeps its provenance.

    WHAT fct_orders NEEDS, and it is narrow: l1_code '04' plus a response
    containing `increment_id:`. Only the server-side order receipts
    (04010100-04040100) carry that KV payload; 04050100 logs a bare value and is
    deliberately excluded there, so it is not generated here either.

    CHANNEL, and why sales apps emit all three. order_source is the ORIGIN of
    the order, not the device that sent it — a rep submitting from a PDA an
    order the customer began in the app logs order_source:APP on source PDA-A.
    Generating APP and WEB only from customer apps would leave both with a null
    sales_code and they would vanish from every per-rep mart, which is exactly
    the shape the real data does NOT have.
    """
    out = OUT_MYSQL / "raw_api" / "system" / "event" / "log"
    out.mkdir(parents=True, exist_ok=True)

    # reuse the capture's usernames so admin_users joins keep hitting
    capture = out / "raw_log.json"
    users = ["salesuser"]
    if capture.exists():
        d = json.load(open(capture, encoding="utf-8"))
        recs = d["data"]["data"] if isinstance(d, dict) and "data" in d else d
        users = sorted({r["username"] for r in recs if r.get("username")}) or users

    # a rep's own accounts, from the NAV customer master this script also writes
    owner = dict(zip(KEYED["customer"]["customer_no"],
                     KEYED["customer"]["salesperson_code"]))
    book: dict[str, list[str]] = {}
    for cust, rep in owner.items():
        book.setdefault(rep, []).append(cust)

    # Sales sources only. A customer-app submit has no sales_code and no
    # rep-day clock, so it cannot appear in a per-rep period table anyway.
    SOURCES = ["PDA-A", "PDA-A", "PDA-A", "CatalogFS-I"]      # PDA-weighted
    CHANNELS = ["PDA"] * 7 + ["APP"] * 2 + ["WEB"]            # 70/20/10
    CODES = ["04020100", "04040100"]                          # sales receipts
    DAYS = 240                                                # ~8 months

    # SOME ACCOUNTS GO QUIET. Without this every account ordered right up to
    # today, so mart_rep_account_status had one overdue account in 200 and
    # mart_rep_nearby_accounts — which only carries accounts needing a call —
    # built to 12 rows. Both looked healthy and neither was being exercised.
    # A quarter of accounts stop 70-200 days back, which straddles
    # var('rep_account_order_overdue_days') (60) so the threshold has cases on
    # each side of it rather than only below.
    quiet_since = {
        cust: rng.randint(70, 200)
        for cust in KEYED["customer"]["customer_no"] if rng.random() < 0.25
    }

    rows = []
    entity = 9_000_000
    seq = 0
    for rep in NAV_REPS:
        accounts = book.get(rep) or NAV_CUSTOMERS
        # one offset per rep, so a rep's local day is stable — int_events_enriched
        # keys its whole timezone pass on this and mixing offsets within a rep
        # is the exact fault its two-pass fix exists to stop
        tz = rng.choice(["GMT-7", "GMT-8"])
        for day in range(DAYS):
            when = NOW - timedelta(days=day)
            if when.weekday() >= 5:            # reps do not sell at weekends
                continue
            for _ in range(rng.randint(0, 4)):
                # an account that has gone quiet takes no orders after its
                # cutoff; `day` counts BACKWARDS, so larger = longer ago
                live = [a for a in accounts if day >= quiet_since.get(a, 0)]
                if not live:
                    continue
                seq += 1
                entity += 1
                channel = rng.choice(CHANNELS)
                subtotal = round(rng.uniform(120, 7500), 2)
                freight = round(rng.uniform(0, 180), 2)
                stamp = when.replace(
                    hour=rng.randint(8, 18), minute=rng.randint(0, 59),
                    second=rng.randint(0, 59))
                rows.append({
                    "entity_id": entity,
                    "sales_code": rep,
                    "username": rng.choice(users),
                    "ust_customer_no": rng.choice(live),
                    "location": "",
                    "timezone": tz,
                    "event_time": stamp.strftime("%Y-%m-%d %H:%M:%S"),
                    "source": rng.choice(SOURCES),
                    "version": "1.92.24b197",
                    "description_code": rng.choice(CODES),
                    # the KV payload fct_orders parses. increment_id is
                    # M-prefixed, which is the submit id space — create-order
                    # ids are 032-prefixed and the two never match.
                    "response": (
                        f"increment_id:M{seq:09d},"
                        f"order_source:{channel},"
                        f"grand_total:{round(subtotal + freight, 2)},"
                        f"subtotal:{subtotal},"
                        f"total_item_count:{rng.randint(1, 40)}"
                    ),
                    "event_id": str(int(stamp.timestamp() * 1000)),
                    "device_name": f"0152{rng.randint(10, 99)}-Honeywell EDA50K",
                    "created_at": stamp.strftime("%Y-%m-%d %H:%M:%S"),
                    "updated_at": stamp.strftime("%Y-%m-%d %H:%M:%S"),
                })

    # SAME ENVELOPE AS THE CAPTURE. stg_mysql__system_event_log unnests
    # data.data, and read_json_auto infers one schema across every globbed file
    # — a different shape here would break the union, not just this file.
    payload = {"code": 200, "msg": "success",
               "data": {"current_page": 1, "data": rows}}
    target = out / "generated_order_events.json"
    json.dump(payload, open(target, "w", encoding="utf-8"), indent=1)
    print(f"mysql.system_event_log: {len(rows)} generated order submits "
          f"-> {target.name} (raw_log.json left untouched)")


def main() -> None:
    schemas = load_snapshot()
    OUT_JDAWMS.mkdir(parents=True, exist_ok=True)
    for table, cols in sorted(schemas["jdawmsrep"].items()):
        # A table in the replica that ROWCOUNTS has never heard of is worth
        # saying out loud, not crashing on: it means the snapshot picked up
        # something new (or something orphaned in the wrong schema).
        if table not in ROWCOUNTS:
            print(f"jdawmsrep.{table}: NOT in ROWCOUNTS - unexpected table, "
                  f"generating {NAV_DEFAULT_ROWS} filler rows. Add a ROWCOUNTS/KEYED "
                  f"entry if it is real, or drop it in UC if it is an orphan.")
        n = ROWCOUNTS.get(table, NAV_DEFAULT_ROWS)
        df = to_frame(table, cols, n, KEYED.get(table, {}))
        df.to_parquet(OUT_JDAWMS / f"{table}.parquet", index=False)
        print(f"jdawmsrep.{table}: {len(df)} rows, {len(cols)} cols")
    mock_nav(schemas)
    mock_geocode(schemas)
    mock_mysql(schemas)
    mock_event_log()


if __name__ == "__main__":
    main()
