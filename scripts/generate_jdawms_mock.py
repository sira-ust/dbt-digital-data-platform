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
NAV_CUSTOMERS = [f"C{i:05d}" for i in range(NAV_DEFAULT_ROWS)]
NAV_ITEMS = [f"ITM{i:05d}" for i in range(NAV_DEFAULT_ROWS)]
NAV_INVOICES = [f"INV{i:06d}" for i in range(NAV_DEFAULT_ROWS)]
NAV_CRMEMOS = [f"CRM{i:06d}" for i in range(NAV_DEFAULT_ROWS)]
# the real territory codes the event-log mock also uses, so a rep who has app
# activity in dev also has NAV invoices to join to
NAV_REPS = ["002", "003", "004", "007", "008", "009", "015", "018",
            "019", "024", "025", "026", "030", "031", "032"]

KEYED["customer"] = {
    "customer_no": list(NAV_CUSTOMERS),
    "salesperson_code": [rng.choice(NAV_REPS) for _ in NAV_CUSTOMERS],
}
KEYED["item"] = {"item_no": list(NAV_ITEMS)}
KEYED["ethnicity_codes"] = {
    "ethnicity_code": [f"ETH{i:03d}" for i in range(NAV_DEFAULT_ROWS)]
}
KEYED["customer_ethnicity"] = {
    "customer_no": [rng.choice(NAV_CUSTOMERS) for _ in range(NAV_DEFAULT_ROWS)]
}

KEYED["sales_invoice_header"] = {
    "document_no": list(NAV_INVOICES),
    "bill_to_customer_no": [rng.choice(NAV_CUSTOMERS) for _ in NAV_INVOICES],
    "salesperson_code": [rng.choice(NAV_REPS) for _ in NAV_INVOICES],
}
# 40 invoices x 5 lines, so (document_no, line_no) is unique AND every
# document_no exists in the header above — the grain the replica actually has.
_inv_lines = [(NAV_INVOICES[i // 5], (i % 5) + 1) for i in range(NAV_DEFAULT_ROWS)]
KEYED["sales_invoice_line"] = {
    "document_no": [d for d, _ in _inv_lines],
    "line_no": [n for _, n in _inv_lines],
    "sell_to_customer_no": [rng.choice(NAV_CUSTOMERS) for _ in _inv_lines],
    "item_no": [rng.choice(NAV_ITEMS) for _ in _inv_lines],
    "salesperson_code": [rng.choice(NAV_REPS) for _ in _inv_lines],
}

KEYED["sales_cr_memo_header"] = {
    "document_no": list(NAV_CRMEMOS),
    "bill_to_customer_no": [rng.choice(NAV_CUSTOMERS) for _ in NAV_CRMEMOS],
    "salesperson_code": [rng.choice(NAV_REPS) for _ in NAV_CRMEMOS],
}
# NO line_no: the replica's projection of Sales Cr_Memo Line omits NAV's
# `Line No_`, so this table has no natural key and CANNOT carry a unique test.
# Duplicates on (document_no, item, qty, date) are real distinct lines, not
# ingestion artefacts — 29,004 of 121,290 rows on the live replica.
KEYED["sales_cr_memo_line"] = {
    "document_no": [NAV_CRMEMOS[i // 5] for i in range(NAV_DEFAULT_ROWS)],
    "sell_to_customer_no": [rng.choice(NAV_CUSTOMERS) for _ in range(NAV_DEFAULT_ROWS)],
    "cr_memo_item_no": [rng.choice(NAV_ITEMS) for _ in range(NAV_DEFAULT_ROWS)],
    "salesperson_code": [rng.choice(NAV_REPS) for _ in range(NAV_DEFAULT_ROWS)],
}

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


if __name__ == "__main__":
    main()
