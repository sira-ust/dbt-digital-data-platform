"""Generate mock parquet for local DuckDB dev — no Unity Catalog access needed.

Reads data/uc_schema_snapshot.csv (produced once by scripts/snapshot_uc_schema.py)
and emits one parquet per table into data/mock/ (git-ignored), mirroring the
two real Unity Catalog schemas under ust_databricks:

  data/mock/jdawmsrep/<table>.parquet  all 16 jdawmsrep tables (WMS replica)
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
OUT_MYSQL = ROOT / "data" / "mock" / "mysql"

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


def main() -> None:
    schemas = load_snapshot()
    OUT_JDAWMS.mkdir(parents=True, exist_ok=True)
    for table, cols in sorted(schemas["jdawmsrep"].items()):
        n = ROWCOUNTS[table]
        df = to_frame(table, cols, n, KEYED.get(table, {}))
        df.to_parquet(OUT_JDAWMS / f"{table}.parquet", index=False)
        print(f"jdawmsrep.{table}: {len(df)} rows, {len(cols)} cols")
    mock_mysql(schemas)


if __name__ == "__main__":
    main()
