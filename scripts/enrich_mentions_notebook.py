# Databricks notebook source
# MAGIC %md
# MAGIC # Enrich mentions (step ② ENRICH) — Databricks runner
# MAGIC
# MAGIC Thin wrapper that runs `enrich_mentions.py` on Databricks. Reads
# MAGIC `social.mentions`, classifies each new mention with the Databricks-hosted
# MAGIC `databricks-claude-haiku-4-5` serving endpoint (no Anthropic key — auth is
# MAGIC the notebook's own Databricks token), and appends flags to
# MAGIC `social.mention_enrichment`.
# MAGIC
# MAGIC **Requires the repo synced via Databricks Git folders** so this notebook and
# MAGIC `enrich_mentions.py` sit in the same `scripts/` folder (Databricks puts the
# MAGIC notebook's directory on `sys.path`, so `import enrich_mentions` resolves).
# MAGIC
# MAGIC **Run order:** parse_mentions → this → dbt build.

# COMMAND ----------

# MAGIC %pip install anthropic
# MAGIC dbutils.library.restartPython()

# COMMAND ----------

# Smoke test first: set limit small (e.g. 25) to sanity-check output + cost,
# then set to empty for a full run.
dbutils.widgets.text("limit", "25")
_limit_raw = dbutils.widgets.get("limit").strip()
LIMIT = int(_limit_raw) if _limit_raw else None

# COMMAND ----------

import enrich_mentions   # same-folder import (Git folders adds the dir to sys.path)

enrich_mentions.main(backend="databricks", limit=LIMIT)

# COMMAND ----------

# Inspect what was written
display(spark.sql("""
    select is_food_relevant, is_spam, sentiment_normalized, count(*) as n,
           round(avg(confidence), 3) as avg_confidence
    from ust_databricks.social.mention_enrichment
    group by 1, 2, 3
    order by n desc
"""))
