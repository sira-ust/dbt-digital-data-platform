"""Geocode NAV customer addresses to lat/lon (OUT-OF-BAND from dbt).

Sibling of scripts/resolve_trending_concepts.py — same shape: dbt stays
deterministic and never calls an external API; this writes a table dbt reads.

WHY A SEPARATE TABLE IN A SEPARATE SCHEMA: navrep is a read-only replication
target owned by the ingestion process -- anything written there is overwritten
by the next replication run, and a hand-written table could be dropped by a
schema sync with nothing to restore it. It would also read as though it were
part of the NAV feed, which it is not. ust_external.nav_customer_geocode says
both things at once: ours, produced out-of-band, derived FROM nav.

WHY IT IS INCREMENTAL: Google Geocoding bills ~$5 per 1,000 lookups. A full
pass over 7,198 customers is ~$36. Re-geocoding an address that has not changed
is pure waste, so every row stores address_hash and only NEW or CHANGED
addresses are sent. A second run costs nothing.

The address cleaning is taken verbatim from the team's geocoding.py so results
match what was validated by hand:
  * a street containing "customer" is dropped (placeholder, not an address)
  * "-" street is dropped, "-" state becomes CA
  * "PICKUP" is stripped out

FAILURES ARE RECORDED, NOT RETRIED FORVER. A row that Google cannot resolve is
written with null coordinates and its status, so the next run skips it instead
of paying again. Clear status to retry a batch after fixing the source address.

Flow position:
    (NAV replication)            ->  navrep.customer
 >> geocode_customers (THIS)     ->  ust_external.nav_customer_geocode
    dbt build --select stg_nav__customer_locations+
                                 ->  int_rep_customer_presence -> the mart

    # cost nothing, see what WOULD be sent:
    python scripts/geocode_customers.py --backend databricks --dry-run

    # real run, capped so a mistake cannot spend the whole budget:
    export GOOGLE_GEOCODING_API_KEY=...
    python scripts/geocode_customers.py --backend databricks --limit 200

    # local dev against the mock parquet
    python scripts/geocode_customers.py --backend local --dry-run
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
import time

import requests

API_KEY_ENV = "GOOGLE_GEOCODING_API_KEY"
GEOCODE_URL = "https://maps.googleapis.com/maps/api/geocode/json"

# Google's free tier allows well above this; 10/s is deliberately polite and
# keeps a full 7k run at roughly 12 minutes.
REQUESTS_PER_SECOND = 10

LOCAL_CUSTOMER = "data/mock/navrep/customer.parquet"
LOCAL_GEOCODE = "data/mock/navrep/customer_geocode.parquet"
DBX_CUSTOMER = "ust_databricks.navrep.customer"
DBX_SCHEMA  = "ust_databricks.ust_external"
DBX_GEOCODE = "ust_databricks.ust_external.nav_customer_geocode"


# ── address cleaning: verbatim from the team's geocoding.py ──────────────────
def build_address(street, city, zip_code, state):
    """Return the single-line address string Google is asked to resolve.

    Kept byte-for-byte compatible with geocoding.py so previously validated
    results reproduce. Returns None when there is nothing worth sending.
    """
    street = (street or "").strip()
    city = (city or "").strip()
    state = (state or "").strip()
    zip_code = (zip_code or "").strip()

    if "customer" in street.lower():
        street = ""
    elif street == "-":
        street = ""
    if state == "-":
        state = "CA"
    street = street.replace("PICKUP", "").strip()

    if not city and not zip_code and not street:
        return None
    return f"{street}, {city}, {state} {zip_code}"


def address_hash(addr: str) -> str:
    return hashlib.sha256(addr.encode("utf-8")).hexdigest()[:16]


def geocode(addr: str, api_key: str):
    """(lat, lon, status). Never raises — a failure is data, not a crash."""
    try:
        r = requests.get(GEOCODE_URL, params={"address": addr, "key": api_key}, timeout=10)
    except Exception as e:                                   # network, DNS, timeout
        return None, None, f"REQUEST_ERROR: {type(e).__name__}"
    if r.status_code != 200:
        return None, None, f"HTTP_{r.status_code}"
    try:
        data = r.json()
    except ValueError:
        return None, None, "BAD_JSON"

    status = data.get("status")
    if status == "OK":
        loc = data["results"][0]["geometry"]["location"]
        return loc["lat"], loc["lng"], "OK"
    # OVER_QUERY_LIMIT means stop, not skip — the caller checks for it
    return None, None, status or "UNKNOWN"


# ── backends ────────────────────────────────────────────────────────────────
def load_local():
    import duckdb
    con = duckdb.connect()
    cust = con.execute(
        f"select customer_no, address, city, county, post_code from '{LOCAL_CUSTOMER}'"
    ).fetchall()
    done = {}
    if os.path.exists(LOCAL_GEOCODE):
        for cn, h in con.execute(
            f"select customer_no, address_hash from '{LOCAL_GEOCODE}'"
        ).fetchall():
            done[cn] = h
    return cust, done


def save_local(rows):
    import duckdb, pandas as pd
    con = duckdb.connect()
    new = pd.DataFrame(rows, columns=[
        "customer_no", "latitude", "longitude", "geocode_status",
        "geocoded_address", "address_hash", "geocoded_at"])
    if os.path.exists(LOCAL_GEOCODE):
        old = con.execute(f"select * from '{LOCAL_GEOCODE}'").df()
        old = old[~old["customer_no"].isin(new["customer_no"])]
        new = pd.concat([old, new], ignore_index=True)
    con.register("d", new)
    con.execute(f"copy d to '{LOCAL_GEOCODE}' (format parquet)")
    return len(new)


def _dbx():
    from databricks import sql as dbsql
    return dbsql.connect(
        server_hostname=os.environ["DATABRICKS_HOST"].replace("https://", ""),
        http_path=os.environ["DATABRICKS_HTTP_PATH"],
        access_token=os.environ["DBT_DATABRICKS_TOKEN"])


def load_dbx():
    con = _dbx(); cur = con.cursor()
    # ust_external, NOT navrep: navrep is a read-only replication target and a
    # hand-written table there could be dropped by a schema sync
    cur.execute(f"create schema if not exists {DBX_SCHEMA}")
    cur.execute(f"""create table if not exists {DBX_GEOCODE} (
        customer_no string, latitude double, longitude double,
        geocode_status string, geocoded_address string,
        address_hash string, geocoded_at timestamp)""")
    cur.execute(f"select customer_no, address, city, county, post_code from {DBX_CUSTOMER}")
    cust = cur.fetchall()
    cur.execute(f"select customer_no, address_hash from {DBX_GEOCODE}")
    done = {r[0]: r[1] for r in cur.fetchall()}
    con.close()
    return cust, done


def save_dbx(rows):
    con = _dbx(); cur = con.cursor()
    keys = ", ".join("'%s'" % r[0].replace("'", "''") for r in rows)
    cur.execute(f"delete from {DBX_GEOCODE} where customer_no in ({keys})")
    values = ", ".join(
        "('{}', {}, {}, '{}', '{}', '{}', current_timestamp())".format(
            r[0].replace("'", "''"),
            "null" if r[1] is None else r[1],
            "null" if r[2] is None else r[2],
            r[3], (r[4] or "").replace("'", "''"), r[5])
        for r in rows)
    cur.execute(f"""insert into {DBX_GEOCODE}
        (customer_no, latitude, longitude, geocode_status, geocoded_address,
         address_hash, geocoded_at) values {values}""")
    cur.execute(f"select count(*) from {DBX_GEOCODE}")
    n = cur.fetchone()[0]
    con.close()
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", choices=["local", "databricks"], required=True)
    ap.add_argument("--dry-run", action="store_true",
                    help="show what WOULD be geocoded; makes no API calls and costs nothing")
    ap.add_argument("--limit", type=int, default=None,
                    help="cap the number of API calls, so a mistake cannot spend the whole budget")
    ap.add_argument("--retry-failed", action="store_true",
                    help="also re-send rows previously recorded as failures")
    a = ap.parse_args()

    customers, done = (load_local() if a.backend == "local" else load_dbx())
    print(f"{len(customers)} customers, {len(done)} already geocoded")

    todo = []
    skipped_no_address = 0
    for cn, street, city, county, post in customers:
        if not cn:
            continue
        addr = build_address(street, city, post, county)
        if addr is None:
            skipped_no_address += 1
            continue
        h = address_hash(addr)
        # only NEW customers, or ones whose address actually changed
        if done.get(cn) == h and not a.retry_failed:
            continue
        todo.append((cn, addr, h))

    print(f"{len(todo)} to geocode  ({skipped_no_address} have no usable address)")
    if a.limit:
        todo = todo[: a.limit]
        print(f"limited to {len(todo)}")
    if not todo:
        print("nothing to do")
        return 0

    est = len(todo) / 1000 * 5
    print(f"estimated Google cost: ${est:.2f}")

    if a.dry_run:
        for cn, addr, _ in todo[:10]:
            print(f"   would send  {cn:<12} {addr}")
        if len(todo) > 10:
            print(f"   ... and {len(todo) - 10} more")
        return 0

    key = os.getenv(API_KEY_ENV)
    if not key:
        print(f"ERROR: {API_KEY_ENV} is not set", file=sys.stderr)
        return 1

    rows, ok, fail = [], 0, 0
    delay = 1.0 / REQUESTS_PER_SECOND
    for i, (cn, addr, h) in enumerate(todo, 1):
        lat, lon, status = geocode(addr, key)
        if status == "OVER_QUERY_LIMIT":
            # stop immediately: continuing just burns quota on guaranteed failures
            print("OVER_QUERY_LIMIT — stopping. Saving what completed.", file=sys.stderr)
            break
        rows.append((cn, lat, lon, status, addr, h, None))
        ok, fail = (ok + 1, fail) if status == "OK" else (ok, fail + 1)
        if i % 100 == 0:
            print(f"   {i}/{len(todo)}  ok={ok} failed={fail}")
        time.sleep(delay)

    if rows:
        total = save_local(rows) if a.backend == "local" else save_dbx(rows)
        print(f"wrote {len(rows)} rows ({ok} resolved, {fail} failed); table now {total} rows")
    if fail:
        print(f"\n{fail} addresses did not resolve — they are stored with their status "
              f"so this run is not repeated. Inspect with:\n"
              f"   select geocode_status, count(*) from customer_geocode "
              f"where latitude is null group by 1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
