"""One-off: upload data/system_events.parquet to Databricks as
ust_databricks.temp_mysql.temp_system_events so the dbt pipeline can be
tested against the databricks target.

Uploads the parquet to a Unity Catalog volume, then CTAS into a Delta
table — one round trip instead of row-by-row inserts.

The temp_ prefix marks this as a sample upload — drop the schema once a
real MySQL ingestion lands (see followup.md). Safe to re-run (drops &
recreates the table).

Requires DBT_DATABRICKS_TOKEN in the environment.
"""

import os
from pathlib import Path

from databricks import sql

HOST = "adb-7405618436278207.7.azuredatabricks.net"
HTTP_PATH = "/sql/1.0/warehouses/e165fed86011619a"
CATALOG = "ust_databricks"
SCHEMA = "temp_mysql"
TABLE = "temp_system_events"
VOLUME = "temp_files"
PARQUET = "data/system_events.parquet"

token = os.environ["DBT_DATABRICKS_TOKEN"]
volume_path = f"/Volumes/{CATALOG}/{SCHEMA}/{VOLUME}/system_events.parquet"
# forward slashes: the connector's allowed-path check mishandles
# backslashes inside the PUT statement on Windows
local_path = Path(PARQUET).resolve().as_posix()
allowed_dir = Path(PARQUET).resolve().parent.as_posix()

# staging_allowed_local_path authorizes the PUT command to read this file;
# the upload rides the SQL connection, so no extra token scopes are needed
conn = sql.connect(
    server_hostname=HOST,
    http_path=HTTP_PATH,
    access_token=token,
    staging_allowed_local_path=allowed_dir,
)
cur = conn.cursor()
cur.execute(f"CREATE SCHEMA IF NOT EXISTS {CATALOG}.{SCHEMA}")
cur.execute(f"CREATE VOLUME IF NOT EXISTS {CATALOG}.{SCHEMA}.{VOLUME}")

print("uploading parquet to", volume_path)
cur.execute(f"PUT '{local_path}' INTO '{volume_path}' OVERWRITE")

cur.execute(f"DROP TABLE IF EXISTS {CATALOG}.{SCHEMA}.{TABLE}")
cur.execute(
    f"CREATE TABLE {CATALOG}.{SCHEMA}.{TABLE} AS "
    f"SELECT * FROM parquet.`{volume_path}`"
)
cur.execute(f"SELECT COUNT(1) FROM {CATALOG}.{SCHEMA}.{TABLE}")
print("table row count:", cur.fetchone()[0])
cur.close()
conn.close()
