"""Enrich Mentionlytics mentions with LLM-derived attributes (step ② of the flow).

Runs OUT-OF-BAND from dbt — after the weekly file is parsed into the mentions
table, before `dbt build`. Reads mentions, asks Claude to read each caption, and
writes multi-label attributes (is_spam, is_food_relevant, themes[], dishes[], …)
to the enrichment table keyed by mention_id. dbt then joins that table; dbt
itself never calls the LLM, so the warehouse build stays deterministic.

LLM access = Databricks-hosted Claude via the workspace serving endpoint
(Option 1). No Anthropic API key: the anthropic SDK is pointed at
https://<host>/serving-endpoints/anthropic and authenticated with a DATABRICKS
token; the model is `databricks-claude-haiku-4-5`. Databricks serving is
synchronous (no Batch API), so mentions are classified concurrently with a
thread pool, and the model is prompted to return strict JSON (structured-output
`output_config` may not pass through the serving proxy).

Two backends, one core:
  --backend local       reads data/mock/mentionlytics/mentions_*.parquet, writes
                        mention_enrichment.parquet. Needs DATABRICKS_HOST +
                        DATABRICKS_TOKEN env vars (a PAT) to reach the endpoint.
  --backend databricks  reads ust_databricks.social.mentions, writes
                        ust_databricks.social.mention_enrichment (Delta).

Runs on Databricks as a **Python-script task** (spark_python_task) — no notebook:
  - Source: Git, path scripts/enrich_mentions.py; Parameters: --backend databricks
  - Dependent libraries (PyPI): anthropic, databricks-sdk
  - Auth is AMBIENT — the task's run-as identity supplies the serving token via
    databricks-sdk (no secret, no PAT, no env vars). The run-as user must have
    model-serving access. (Local runs still use DATABRICKS_HOST/DATABRICKS_TOKEN.)

Incremental: only mention_ids not already enriched are classified. Multi-label
by design — arrays, never a single category key.

Local smoke test (needs a Databricks PAT in env):
    python scripts/enrich_mentions.py --backend local --limit 10
    python scripts/enrich_mentions.py --backend local --dry-run   # build prompts only, no calls
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

# ─────────────────────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────────────────────

MODEL = "databricks-claude-haiku-4-5"   # Databricks-hosted; billed via Databricks
PROMPT_VERSION = "v1"                    # bump when INSTRUCTIONS change (stored in model_version)
MAX_TOKENS = 512
CONCURRENCY = 4                          # parallel serving calls — lower if you hit FMAPI rate limits
MAX_RETRIES = 8                          # SDK-level retries: rides out 429s with backoff + retry-after
MAX_ATTEMPTS = 2                         # our own retries on bad/empty JSON
BATCH_SIZE = 300                         # write to the table every N classified (checkpoint / resumable)

LOCAL_MENTIONS_GLOB = "data/mock/mentionlytics/mentions_*.parquet"
LOCAL_ENRICHMENT_PATH = "data/mock/mentionlytics/mention_enrichment.parquet"
DBX_MENTIONS_TABLE = "ust_databricks.social.mentions"
DBX_ENRICHMENT_TABLE = "ust_databricks.social.mention_enrichment"

# Prompt-for-JSON: the exact object shape is described here (no output_config).
# Arrays are multi-label (empty = none); confidence is 0.0–1.0.
INSTRUCTIONS = """You classify social-listening mentions captured for Thai and \
Vietnamese food & beverage market research. Read the mention's title and content \
and extract structured attributes.

Respond with ONLY a single JSON object — no markdown, no code fence, no prose — \
with exactly these keys:
{
  "is_food_relevant": boolean,   // true only if genuinely about food or beverages
  "is_spam": boolean,            // gambling/casino promos (e.g. 789BET), unrelated ads, bots
  "themes": [string],            // broad topics: "street food", "dessert", "coffee", "restaurant review"...
  "mentioned_dishes": [string],  // specific dishes: "banh khot", "pho", "mango sticky rice"...
  "ingredients": [string],       // notable ingredients: "fish sauce", "coconut milk"...
  "brands": [string],            // brand / restaurant / product names
  "sentiment_normalized": string,// one of "positive", "negative", "neutral"
  "confidence": number           // 0.0–1.0, your overall certainty
}

Rules: extract MULTIPLE labels where they apply — a post can mention several \
dishes, ingredients, and brands. Use empty arrays when none apply; never force a \
single category. is_spam is true for gambling/ads/bots regardless of food \
keywords present. Content may be Thai, Vietnamese, English, or other languages — \
judge on meaning, not keywords."""

_REQUIRED_KEYS = {
    "is_food_relevant", "is_spam", "themes", "mentioned_dishes",
    "ingredients", "brands", "sentiment_normalized", "confidence",
}


# ─────────────────────────────────────────────────────────────────────────────
# Serving-endpoint client (Databricks-hosted Claude)
# ─────────────────────────────────────────────────────────────────────────────

def _resolve_host_token(backend):
    """Databricks workspace host + serving token. Env vars win (DATABRICKS_HOST /
    DATABRICKS_TOKEN — used for local runs with a PAT). Otherwise, on the
    databricks backend, use AMBIENT auth via databricks-sdk: the compute's run-as
    identity supplies the token, so no PAT and no secret are needed (the run-as
    user must have model-serving access)."""
    host = os.environ.get("DATABRICKS_HOST")
    token = os.environ.get("DATABRICKS_TOKEN")
    if backend == "databricks" and (not host or not token):
        from databricks.sdk.core import Config
        cfg = Config()
        host = host or cfg.host
        if not token:
            bearer = (cfg.authenticate() or {}).get("Authorization", "")
            if bearer.lower().startswith("bearer "):
                token = bearer.split(" ", 1)[1]
    if not host or not token:
        raise SystemExit(
            "Need a Databricks host + token: set DATABRICKS_HOST / DATABRICKS_TOKEN "
            "for local runs, or run on Databricks compute (ambient auth)."
        )
    return host.replace("https://", "").rstrip("/"), token


def get_client(backend):
    import anthropic
    host, token = _resolve_host_token(backend)
    # Per Databricks docs: point the SDK at the serving endpoint, api_key unused,
    # real auth via the Bearer header.
    return anthropic.Anthropic(
        api_key="unused",
        base_url=f"https://{host}/serving-endpoints/anthropic",
        default_headers={"Authorization": f"Bearer {token}"},
        max_retries=MAX_RETRIES,   # backs off + honors retry-after on 429/5xx
    )


# ─────────────────────────────────────────────────────────────────────────────
# Backend I/O
# ─────────────────────────────────────────────────────────────────────────────

def _dedup_sql(source: str) -> str:
    """One row per mention (latest export), mirroring the staging dedupe."""
    return f"""
        select mention_id, channel, tracker, keyword, title, content
        from (
            select
                id as mention_id, channel, tracker, keyword, title, content,
                row_number() over (partition by id order by loaded_at desc) as rn
            from {source}
        )
        where rn = 1
    """


def read_mentions_and_enriched(backend, limit):
    """Return (list of new mention dicts to classify, count already enriched)."""
    if backend == "databricks":
        spark = _get_spark()
        rows = [r.asDict() for r in spark.sql(_dedup_sql(DBX_MENTIONS_TABLE)).collect()]
        try:
            enriched_ids = {r.mention_id for r in
                            spark.table(DBX_ENRICHMENT_TABLE).select("mention_id").collect()}
        except Exception:
            enriched_ids = set()
    else:
        import duckdb
        con = duckdb.connect()
        rows = con.sql(
            _dedup_sql(f"read_parquet('{LOCAL_MENTIONS_GLOB}', union_by_name = true)")
        ).df().to_dict("records")
        try:
            enriched_ids = set(
                con.sql(f"select mention_id from read_parquet('{LOCAL_ENRICHMENT_PATH}')")
                .df()["mention_id"].tolist()
            )
        except Exception:
            enriched_ids = set()

    new = [r for r in rows if r["mention_id"] not in enriched_ids]
    if limit:
        new = new[:limit]
    return new, len(enriched_ids)


def write_enrichment(backend, records):
    if not records:
        return
    if backend == "databricks":
        spark = _get_spark()
        df = spark.createDataFrame(records, schema=_dbx_enrichment_schema())
        (df.write.format("delta").mode("append")
           .option("mergeSchema", "true").saveAsTable(DBX_ENRICHMENT_TABLE))
    else:
        import pandas as pd
        new_df = pd.DataFrame(records)
        if os.path.exists(LOCAL_ENRICHMENT_PATH):
            new_df = pd.concat([pd.read_parquet(LOCAL_ENRICHMENT_PATH), new_df], ignore_index=True)
        new_df.to_parquet(LOCAL_ENRICHMENT_PATH, index=False)


def _dbx_enrichment_schema():
    from pyspark.sql.types import (
        StructType, StructField, LongType, BooleanType, StringType,
        DoubleType, ArrayType, TimestampType,
    )
    arr = ArrayType(StringType())
    return StructType([
        StructField("mention_id", LongType()),
        StructField("is_food_relevant", BooleanType()),
        StructField("is_spam", BooleanType()),
        StructField("themes", arr),
        StructField("mentioned_dishes", arr),
        StructField("ingredients", arr),
        StructField("brands", arr),
        StructField("sentiment_normalized", StringType()),
        StructField("confidence", DoubleType()),
        StructField("enriched_at", TimestampType()),
        StructField("model_version", StringType()),
    ])


def _get_spark():
    try:
        return spark  # noqa: F821 — global in Databricks notebooks
    except NameError:
        from pyspark.sql import SparkSession
        return SparkSession.builder.getOrCreate()


# ─────────────────────────────────────────────────────────────────────────────
# LLM core
# ─────────────────────────────────────────────────────────────────────────────

def build_user_prompt(m):
    return (
        f"Channel: {m.get('channel')}\n"
        f"Tracker: {m.get('tracker')}\n"
        f"Keyword: {m.get('keyword')}\n"
        f"Title: {m.get('title')}\n"
        f"Content: {m.get('content')}"
    )


def extract_json(text):
    """Parse the model's reply into a dict, tolerating stray fences/prose."""
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\n?", "", text)
        text = re.sub(r"\n?```$", "", text).strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", text, re.DOTALL)  # first {...} block
        return json.loads(m.group(0)) if m else None


def classify_one(client, m):
    """Return an attributes dict for one mention, or None on repeated failure."""
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            resp = client.messages.create(
                model=MODEL,
                max_tokens=MAX_TOKENS,
                system=INSTRUCTIONS,
                messages=[{"role": "user", "content": build_user_prompt(m)}],
            )
            text = next((b.text for b in resp.content if b.type == "text"), "")
            data = extract_json(text)
            if data and _REQUIRED_KEYS.issubset(data):
                return data
        except Exception as e:  # transient serving error, rate limit, etc.
            if attempt == MAX_ATTEMPTS:
                print(f"  WARN mention {m['mention_id']}: {e}", file=sys.stderr)
    return None


def classify_batch(client, mentions, concurrency):
    """Concurrently classify one batch. Returns {mention_id: attributes}."""
    out = {}
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = {pool.submit(classify_one, client, m): m for m in mentions}
        for fut in futures:
            m = futures[fut]
            data = fut.result()
            if data is not None:
                out[m["mention_id"]] = data
    return out


def to_records(attrs_by_id, enriched_at):
    model_version = f"{MODEL}/{PROMPT_VERSION}"
    records = []
    for mention_id, a in attrs_by_id.items():
        records.append({
            "mention_id": int(mention_id),
            "is_food_relevant": bool(a["is_food_relevant"]),
            "is_spam": bool(a["is_spam"]),
            "themes": list(a["themes"]),
            "mentioned_dishes": list(a["mentioned_dishes"]),
            "ingredients": list(a["ingredients"]),
            "brands": list(a["brands"]),
            "sentiment_normalized": str(a["sentiment_normalized"]),
            "confidence": float(a["confidence"]),
            "enriched_at": enriched_at,
            "model_version": model_version,
        })
    return records


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def main(backend="local", limit=None, dry_run=False, concurrency=CONCURRENCY):
    mentions, n_enriched = read_mentions_and_enriched(backend, limit)
    print(f"{n_enriched} already enriched; {len(mentions)} new to classify")
    if not mentions:
        print("nothing to do.")
        return

    if dry_run:
        print(f"[dry-run] would classify {len(mentions)} mentions with {MODEL}. First prompt:\n")
        print(build_user_prompt(mentions[0]))
        return

    client = get_client(backend)
    total = len(mentions)
    written = 0
    # Process in batches and WRITE each batch — checkpoints progress so nothing is
    # lost if the run is interrupted, and a re-run resumes (incremental read skips
    # what's already written).
    for start in range(0, total, BATCH_SIZE):
        chunk = mentions[start:start + BATCH_SIZE]
        attrs = classify_batch(client, chunk, concurrency)
        write_enrichment(backend, to_records(attrs, datetime.now(timezone.utc)))
        written += len(attrs)
        print(f"  batch {start // BATCH_SIZE + 1}: wrote {len(attrs)}/{len(chunk)} "
              f"(cumulative {written}/{total})")

    failed = total - written
    print(f"DONE. wrote {written} enrichment rows"
          + (f"; {failed} failed — re-run to backfill (incremental)" if failed else ""))


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--backend", choices=["local", "databricks"], default="local")
    p.add_argument("--limit", type=int, help="classify at most N new mentions (smoke test)")
    p.add_argument("--concurrency", type=int, default=CONCURRENCY,
                   help=f"parallel serving calls (default {CONCURRENCY}); lower if rate-limited")
    p.add_argument("--dry-run", action="store_true", help="build prompts only; no API call")
    args = p.parse_args()
    try:
        sys.stdout.reconfigure(encoding="utf-8")  # mentions carry Thai/Vietnamese text
    except Exception:
        pass
    main(backend=args.backend, limit=args.limit, dry_run=args.dry_run, concurrency=args.concurrency)
