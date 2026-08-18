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

FAILURES ARE RECORDED, NOT RETRIED FOREVER. A row that Google cannot resolve is
written with null coordinates and its status, so the next run skips it instead
of paying again. Clear status to retry a batch after fixing the source address.

Flow position:
    (NAV replication)            ->  navrep.customer
 >> geocode_customers (THIS)     ->  ust_external.nav_customer_geocode
    dbt build --select stg_nav__customer_locations+
                                 ->  int_rep_customer_presence -> the mart

RUN IT FROM A TERMINAL, NOT THE DAILY JOB. It was a task in
ust_digital_platform_dbt and was removed on 2026-08-17: incremental means a
normal day sends zero requests, so the job paid a serverless cold start every
night to do nothing, and a Google outage produced a FAILED task and a morning
alert for a problem that does not touch the warehouse. See
scripts/databricks/job.yml for the full reasoning.

    # against Databricks. Needs TWO credentials:
    #   GOOGLE_GEOCODING_API_KEY -- third party, no ambient auth exists for it
    #   DBT_DATABRICKS_TOKEN     -- the same PAT dbt uses; host and http_path
    #                               come from profiles.yml, so nothing to repeat
    export GOOGLE_GEOCODING_API_KEY=...
    export DBT_DATABRICKS_TOKEN=...
    python scripts/geocode_customers.py --backend databricks --dry-run   # free
    python scripts/geocode_customers.py --backend databricks             # real

WHY NO --limit ON A MANUAL RUN: --limit is a blast-radius cap for UNATTENDED
runs, where an upstream address rewrite could silently spend ~$36. Watching the
output, the cap only turns a twenty-minute backfill into a fortnight of partial
runs. Use it when testing, omit it when draining the backlog.

THE KEY LIVES IN UNITY CATALOG, at
ust_databricks.ust_external.google_geocoding_api_key. UC secrets are addressed
by catalog/schema/key -- NOT the scope/key of workspace secret scopes, which is
a separate store. Calling the scope form against a UC secret returns
ResourceDoesNotExist, which reads like a missing key but means a missing SCOPE.
Reading a UC secret with dbutils needs DBR 17.3 LTS+ or serverless environment
version 4+; the geocode job pins version 5.

Off Databricks there is no dbutils, so a local run falls back to the UC REST
endpoint using DATABRICKS_TOKEN / DBT_DATABRICKS_TOKEN -- meaning the one stored
secret serves both the job and the terminal. Setting GOOGLE_GEOCODING_API_KEY
still short-circuits all of it.

    # local dev against the mock parquet -- no credentials, no cost
    python scripts/geocode_customers.py --backend local --dry-run
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
import time

import requests

# The Windows console defaults to cp1252, where printing any non-ASCII character
# raises UnicodeEncodeError. That killed a run *after* the Google calls had been
# billed -- the worst possible place to fail. Force UTF-8 and downgrade an
# unencodable character to a replacement rather than an exception: a garbled
# glyph in a log is a cosmetic problem, a crash costs money.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):                  # already wrapped/redirected
        pass

API_KEY_ENV = "GOOGLE_GEOCODING_API_KEY"
GEOCODE_URL = "https://maps.googleapis.com/maps/api/geocode/json"

# Google's free tier allows well above this; 10/s is deliberately polite and
# keeps a full 7k run at roughly 12 minutes.
REQUESTS_PER_SECOND = 10

# Persist every N results. A 7,198-row run takes ~20 minutes; without
# checkpointing, an interruption at minute 19 loses everything and has still
# been billed for it.
CHECKPOINT_EVERY = 50

LOCAL_CUSTOMER = "data/mock/navrep/customer.parquet"
LOCAL_GEOCODE = "data/mock/navrep/customer_geocode.parquet"
DBX_CUSTOMER = "ust_databricks.navrep.customer"
DBX_SCHEMA  = "ust_databricks.ust_external"
DBX_GEOCODE = "ust_databricks.ust_external.nav_customer_geocode"


# -- address cleaning: verbatim from the team's geocoding.py ------------------
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


# -- backends ----------------------------------------------------------------
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


DDL = f"""create table if not exists {DBX_GEOCODE} (
    customer_no string, latitude double, longitude double,
    geocode_status string, geocoded_address string,
    address_hash string, geocoded_at timestamp)"""


def _spark():
    """Spark session when running ON Databricks compute, else None.

    Same shape as enrich_mentions.py / resolve_trending_concepts.py: on
    Databricks the job's run-as identity authenticates ambiently, so no PAT and
    no secret are needed just to reach our own workspace. A PAT is only for
    local runs.
    """
    try:
        from pyspark.sql import SparkSession
        return SparkSession.builder.getOrCreate()
    except Exception:
        return None


def _profile_target():
    """host + http_path from profiles.yml, so a local run needs no duplicate config.

    dbt already knows how to reach the workspace; making the operator re-declare
    it as env vars is a second copy that can drift. Env vars still win when set,
    for anyone running outside a dbt checkout.
    """
    import yaml
    for candidate in (
        os.environ.get("DBT_PROFILES_DIR", "") + "/profiles.yml",
        "profiles.yml",
        os.path.expanduser("~/.dbt/profiles.yml"),
    ):
        if candidate and os.path.exists(candidate):
            with open(candidate) as fh:
                cfg = yaml.safe_load(fh) or {}
            for prof in cfg.values():
                if not isinstance(prof, dict):
                    continue
                out = (prof.get("outputs") or {}).get("databricks")
                if out and out.get("host") and out.get("http_path"):
                    return out["host"], out["http_path"], candidate
    return None, None, None


def _api_key(scope, name, catalog=None, schema=None):
    """The Google key: env var first, then the Databricks secret store.

    Reading the secret HERE rather than injecting it as a task environment
    variable means the job needs no env-var wiring — serverless task specs do
    not reliably support it, and a value passed as a task parameter would be
    visible in the job definition and run history.
    """
    key = os.getenv(API_KEY_ENV)
    if key:
        return key
    try:
        from databricks.sdk.runtime import dbutils
    except Exception:
        dbutils = None

    errors = []

    # 1. UNITY CATALOG secret -- where the key actually lives, as
    #    ust_databricks.ust_external.google_geocoding_api_key. UC secrets take
    #    catalog/schema/key, NOT scope/key: a UC secret is a securable in a
    #    catalog namespace, and the scope-based call cannot address one (it
    #    answers ResourceDoesNotExist, which reads like a missing key but means
    #    a missing SCOPE). Requires DBR 17.3 LTS+ or serverless environment
    #    version 4+; the geocode job pins version 5.
    if dbutils is not None and catalog and schema:
        try:
            return dbutils.secrets.get(catalog=catalog, schema=schema, key=name)
        except Exception as e:
            errors.append(f"uc/dbutils: {type(e).__name__}")

    # 2. Legacy secret SCOPE, for a workspace where the key was put in a scope
    #    instead. Kept because it costs nothing and the two stores coexist.
    if dbutils is not None and scope:
        try:
            return dbutils.secrets.get(scope=scope, key=name)
        except Exception as e:
            errors.append(f"scope/dbutils: {type(e).__name__}")

    # 3. OFF-RUNTIME (a local terminal run): no dbutils exists, so go at the UC
    #    secret through its REST endpoint with whatever token is around. This is
    #    what lets one stored secret serve both the job and a local run.
    #    NOTE: values fetched this way are NOT subject to secret redaction, so
    #    this must never be echoed -- it is returned, never printed.
    if catalog and schema:
        try:
            host, tok = _ambient_token()
            host = os.environ.get("DATABRICKS_HOST") or host
            tok = (os.environ.get("DATABRICKS_TOKEN")
                   or os.environ.get("DBT_DATABRICKS_TOKEN") or tok)
            if not host:
                host, _, _ = _profile_target()
            if host and tok:
                if not host.startswith("http"):
                    host = "https://" + host
                r = requests.get(
                    f"{host.rstrip('/')}/api/2.1/unity-catalog/secrets/"
                    f"{catalog}.{schema}.{name}",
                    headers={"Authorization": f"Bearer {tok}"},
                    params={"include_value": "true"}, timeout=15)
                if r.status_code == 200:
                    val = r.json().get("effective_value")
                    if val:
                        return val
                errors.append(f"uc/rest: HTTP {r.status_code}")
        except Exception as e:
            errors.append(f"uc/rest: {type(e).__name__}")

    # 4. Legacy scope over the SDK, the off-runtime twin of 2.
    if scope:
        try:
            from databricks.sdk import WorkspaceClient
            import base64
            raw = WorkspaceClient().secrets.get_secret(scope=scope, key=name).value
            return base64.b64decode(raw).decode()
        except Exception as e:
            errors.append(f"scope/sdk: {type(e).__name__}")

    print(f"ERROR: no Google API key. Set {API_KEY_ENV}, or store it as a "
          f"Databricks secret -- Unity Catalog at "
          f"'{catalog}.{schema}.{name}' (--secret-catalog / --secret-schema), "
          f"or a legacy scope at '{scope}' key '{name}' (--secret-scope). "
          f"Tried: {'; '.join(errors) or 'nothing'}", file=sys.stderr)
    return None


def _ambient_token():
    """Token from the Databricks SDK credential chain, when running on Databricks.

    Needed for SERVERLESS python tasks: those may have no SparkSession, and no
    PAT is injected either — but the SDK resolves the run-as identity ambiently.
    Without this, a serverless task would have no way to authenticate at all.
    Returns (host, token) or (None, None) off-platform.
    """
    try:
        from databricks.sdk.core import Config
        cfg = Config()
        headers = cfg.authenticate()                 # raises off-platform
        auth = headers.get("Authorization", "")
        if auth.startswith("Bearer ") and cfg.host:
            return cfg.host, auth[len("Bearer "):]
    except Exception:
        pass
    return None, None


def _sql_conn():
    """SQL-connector path: serverless job task, or a local run with a PAT."""
    from databricks import sql as dbsql
    host = os.environ.get("DATABRICKS_HOST")
    path = os.environ.get("DATABRICKS_HTTP_PATH")
    src = "env vars"
    if not (host and path):
        host, path, src = _profile_target()
    tok = os.environ.get("DATABRICKS_TOKEN") or os.environ.get("DBT_DATABRICKS_TOKEN")
    if not tok:
        amb_host, amb_tok = _ambient_token()
        if amb_tok:
            tok, src = amb_tok, "ambient (Databricks run-as identity)"
            host = host or amb_host

    if not (host and path):
        raise SystemExit(
            "Cannot find the Databricks workspace. Either run this on Databricks "
            "compute (ambient auth, nothing to set), or make sure profiles.yml has "
            "a `databricks` output, or set DATABRICKS_HOST / DATABRICKS_HTTP_PATH.")
    if not tok:
        raise SystemExit(
            "No Databricks token. On Databricks the run-as identity should supply "
            "one ambiently; locally set DBT_DATABRICKS_TOKEN (the same one dbt "
            "uses) or DATABRICKS_TOKEN.")

    print(f"connecting to {host} (from {src})")
    return dbsql.connect(server_hostname=host.replace("https://", ""),
                         http_path=path, access_token=tok)


def load_dbx():
    # ust_external, NOT navrep: navrep is a read-only replication target and a
    # hand-written table there could be dropped by a schema sync
    spark = _spark()
    if spark is not None:
        spark.sql(f"create schema if not exists {DBX_SCHEMA}")
        spark.sql(DDL)
        cust = [tuple(r) for r in spark.sql(
            f"select customer_no, address, city, county, post_code from {DBX_CUSTOMER}"
        ).collect()]
        done = {r[0]: r[1] for r in spark.sql(
            f"select customer_no, address_hash from {DBX_GEOCODE}").collect()}
        return cust, done

    con = _sql_conn(); cur = con.cursor()
    cur.execute(f"create schema if not exists {DBX_SCHEMA}")
    cur.execute(DDL)
    cur.execute(f"select customer_no, address, city, county, post_code from {DBX_CUSTOMER}")
    cust = cur.fetchall()
    cur.execute(f"select customer_no, address_hash from {DBX_GEOCODE}")
    done = {r[0]: r[1] for r in cur.fetchall()}
    con.close()
    return cust, done


def save_dbx(rows):
    spark = _spark()
    keys = ", ".join("'%s'" % r[0].replace("'", "''") for r in rows)
    # delete-then-insert so a re-geocoded customer replaces its old row rather
    # than accumulating duplicates
    delete = f"delete from {DBX_GEOCODE} where customer_no in ({keys})"

    if spark is not None:
        import datetime as _dt
        spark.sql(delete)
        now = _dt.datetime.utcnow()
        df = spark.createDataFrame(
            [(r[0], r[1], r[2], r[3], r[4], r[5], now) for r in rows],
            "customer_no string, latitude double, longitude double, "
            "geocode_status string, geocoded_address string, "
            "address_hash string, geocoded_at timestamp")
        df.write.mode("append").saveAsTable(DBX_GEOCODE)
        return spark.sql(f"select count(*) from {DBX_GEOCODE}").collect()[0][0]

    con = _sql_conn(); cur = con.cursor()
    cur.execute(delete)
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


def summary(total, with_row, backlog, written, ok, fail):
    """One scannable block at the end of every run.

    This is the ONLY place per-run volume is visible: the Databricks task log
    keeps stdout, but nothing else records how much this particular run did. It
    prints even when there was nothing to do -- on a daily schedule that is the
    normal case, and a run that says nothing is indistinguishable from a run
    that did not fire.

    `coverage` is deliberately "has a row", not "has coordinates": a permanently
    unresolvable address gets a row with its failure status so it is not paid
    for again, and counting it as missing would make the backlog look stuck
    forever.
    """
    print("", flush=True)
    print("-" * 46)
    print(f"  geocode run summary")
    print(f"    sent to Google    : {written}")
    print(f"      resolved        : {ok}")
    print(f"      failed          : {fail}")
    print(f"    customers total   : {total}")
    print(f"    coverage          : {with_row} ({with_row / total:.1%})" if total
          else "    coverage          : n/a")
    print(f"    still to geocode  : {max(backlog - written, 0)}")
    print("-" * 46, flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", choices=["local", "databricks"], required=True)
    ap.add_argument("--dry-run", action="store_true",
                    help="show what WOULD be geocoded; makes no API calls and costs nothing")
    ap.add_argument("--limit", type=int, default=None,
                    help="cap the number of API calls, so a mistake cannot spend the whole budget")
    ap.add_argument("--retry-failed", action="store_true",
                    help="also re-send rows previously recorded as failures")
    ap.add_argument("--secret-catalog", default="ust_databricks",
                    help="Unity Catalog catalog holding the Google key secret")
    ap.add_argument("--secret-schema", default="ust_external",
                    help="Unity Catalog schema holding the Google key secret")
    ap.add_argument("--secret-scope", default="ust_external",
                    help="LEGACY secret scope, tried only if the UC secret misses")
    ap.add_argument("--secret-key", default="google_geocoding_api_key",
                    help="secret name within that scope")
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
    todo_all = list(todo)          # pre-limit, so the summary can report the real backlog
    if a.limit:
        todo = todo[: a.limit]
        print(f"limited to {len(todo)}")
    if not todo:
        print("nothing to do")
        summary(len(customers), len(done), 0, 0, 0, 0)
        return 0

    est = len(todo) / 1000 * 5
    print(f"estimated Google cost: ${est:.2f}")

    if a.dry_run:
        for cn, addr, _ in todo[:10]:
            print(f"   would send  {cn:<12} {addr}")
        if len(todo) > 10:
            print(f"   ... and {len(todo) - 10} more")
        return 0

    key = _api_key(a.secret_scope, a.secret_key,
                   catalog=a.secret_catalog, schema=a.secret_schema)
    if not key:
        return 1

    save = save_local if a.backend == "local" else save_dbx
    rows, ok, fail, written = [], 0, 0, 0
    # customers persisted this run. Needed because `written` counts API calls,
    # and a re-geocoded changed address REPLACES its old row -- adding it to the
    # coverage count would inflate coverage above the customer count.
    seen = set()
    delay = 1.0 / REQUESTS_PER_SECOND

    def flush(batch):
        """Persist a batch. CHECKPOINTING MATTERS: without it, a run killed at
        row 6,000 of 7,198 loses every geocode AND has still paid for them."""
        nonlocal written
        if not batch:
            return
        save(batch)
        written += len(batch)
        seen.update(r[0] for r in batch)
        batch.clear()

    try:
        for i, (cn, addr, h) in enumerate(todo, 1):
            lat, lon, status = geocode(addr, key)
            if status == "OVER_QUERY_LIMIT":
                # stop immediately: continuing just burns quota on guaranteed failures
                print("OVER_QUERY_LIMIT — stopping. Saving what completed.", file=sys.stderr)
                break
            rows.append((cn, lat, lon, status, addr, h, None))
            ok, fail = (ok + 1, fail) if status == "OK" else (ok, fail + 1)

            # every 10, not every 100: at ~3 requests/sec real-world, 100 is
            # forty seconds of silence and looks like a hang
            if i % 10 == 0 or i == len(todo):
                print(f"   {i}/{len(todo)}  ok={ok} failed={fail}", flush=True)
            if len(rows) >= CHECKPOINT_EVERY:
                flush(rows)
                print(f"   ...checkpointed {written}", flush=True)
            time.sleep(delay)
    except KeyboardInterrupt:
        print("interrupted — saving what completed so it is not paid for twice",
              file=sys.stderr)

    flush(rows)

    # set(done), not done: `done` maps customer_no -> address_hash, and unioning
    # a dict with a set is a TypeError
    summary(len(customers), len(set(done) | seen), len(todo_all), written, ok, fail)
    if fail:
        print(f"\n{fail} addresses did not resolve — they are stored with their status "
              f"so this run is not repeated. Inspect with:\n"
              f"   select geocode_status, count(*) from customer_geocode "
              f"where latitude is null group by 1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
