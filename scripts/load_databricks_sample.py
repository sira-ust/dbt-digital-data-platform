"""
Loads the local sample JSON into temp_mysql.* tables on Databricks.

This mirrors the established POC pattern (temp_mysql.temp_system_events):
the dbt sources read these tables on the Databricks target via
identifier: temp_*  (external_location is DuckDB-only and ignored there).

All columns are typed STRING — the staging models do the typing/casting.
The system event log JSON has a nested envelope; we load the flattened
events array (one row per event) into temp_system_events.

Usage:
    $env:DBT_DATABRICKS_TOKEN = "<token>"      # PowerShell
    python scripts/load_databricks_sample.py
"""

import json
import os
import sys

import databricks.sql as dbsql

HOST = "adb-7405618436278207.7.azuredatabricks.net"
HTTP_PATH = "/sql/1.0/warehouses/e165fed86011619a"
CATALOG = "ust_databricks"
SCHEMA = "temp_mysql"

# table -> (json path, is_nested, ordered column list matching the source yml)
DATASETS = {
    "temp_tracking_report": (
        "data/raw_api/customer/tracking/customer_reports.json", False,
        ["entity_id", "customer_id", "customer_name", "session_id", "model",
         "version", "start_time", "end_time", "total_event", "create_at",
         "updated_at"],
    ),
    "temp_tracking_report_event": (
        "data/raw_api/customer/tracking/customer_events.json", False,
        ["entity_id", "parent_id", "customer_id", "customer_name", "type",
         "title", "start_time", "end_time", "item_no", "sku", "qty", "quote_id",
         "keyword", "page", "event_type", "notes", "address", "source", "second",
         "method", "categories_name", "icon", "timezone", "version", "create_at",
         "updated_at"],
    ),
    "temp_user_activity_report": (
        "data/raw_api/user/activity/sales_reports.json", False,
        ["entity_id", "user", "user_name", "session_id", "begin_time",
         "end_time", "event_count", "voluntarily_exit", "model", "location",
         "sales_name", "version", "created_at", "updated_at"],
    ),
    "temp_user_activity_report_event": (
        "data/raw_api/user/activity/sales_events.json", False,
        ["entity_id", "report_entity_id", "user", "user_name", "sales_code",
         "act_type", "begin_time", "end_time", "customer", "keyword", "location",
         "category", "visits_num", "sku", "title", "qty", "response", "battery",
         "is_wifi", "is_done", "is_login", "device_space", "timezone", "method",
         "version", "updated_at"],
    ),
    "temp_system_events": (
        "data/raw_api/system/event/log/raw_log.json", True,
        ["entity_id", "sales_code", "username", "ust_customer_no", "location",
         "timezone", "event_time", "source", "version", "description_code",
         "response", "device_name", "created_at", "updated_at", "event_id"],
    ),
}

BATCH = 500


def load_records(path, is_nested):
    data = json.load(open(path, encoding="utf-8"))
    if is_nested:
        return data["data"]["data"]
    return data


def to_str(v):
    if v is None:
        return None
    if isinstance(v, (dict, list)):
        return json.dumps(v, ensure_ascii=False)
    return str(v)


def sql_literal(v):
    """Spark SQL string literal (default escapedStringLiterals=false)."""
    s = to_str(v)
    if s is None:
        return "NULL"
    s = s.replace("\\", "\\\\").replace("'", "\\'")
    return "'" + s + "'"


def main():
    token = os.environ.get("DBT_DATABRICKS_TOKEN")
    if not token:
        sys.exit("DBT_DATABRICKS_TOKEN not set")

    con = dbsql.connect(
        server_hostname=HOST, http_path=HTTP_PATH, access_token=token
    )
    cur = con.cursor()
    cur.execute(f"create schema if not exists {CATALOG}.{SCHEMA}")

    for table, (path, is_nested, cols) in DATASETS.items():
        fq = f"{CATALOG}.{SCHEMA}.{table}"
        records = load_records(path, is_nested)
        print(f"{table}: {len(records)} records from {path}", flush=True)

        col_defs = ", ".join(f"`{c}` string" for c in cols)
        cur.execute(f"drop table if exists {fq}")
        cur.execute(f"create table {fq} ({col_defs}) using delta")

        col_list = ", ".join("`" + c + "`" for c in cols)
        value_rows = [
            "(" + ", ".join(sql_literal(rec.get(c)) for c in cols) + ")"
            for rec in records
        ]
        for i in range(0, len(value_rows), BATCH):
            chunk = ",\n".join(value_rows[i:i + BATCH])
            cur.execute(f"insert into {fq} ({col_list}) values {chunk}")
            print(f"   inserted {min(i + BATCH, len(value_rows))}/{len(value_rows)}", flush=True)
        print(f"   loaded {len(value_rows)} rows -> {fq}", flush=True)

    # admin_users / category: empty placeholder tables (staging stubs return
    # empty while mysql_available=false, so these are only for completeness).
    cur.execute(f"drop table if exists {CATALOG}.{SCHEMA}.temp_admin_users")
    cur.execute(f"drop table if exists {CATALOG}.{SCHEMA}.temp_category")

    cur.close()
    con.close()
    print("\nDone. Now run:  dbt build --target databricks")


if __name__ == "__main__":
    main()
