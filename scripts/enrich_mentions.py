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

Reads the dbt STAGING model (stg_mentionlytics__mentions), so dbt must build
staging BEFORE this runs — the LLM only ever sees deduped, cleaned rows and the
dedup/clean logic isn't re-implemented here. Job order: parse -> dbt (staging) ->
enrich -> dbt (rest).

Two backends, one core:
  --backend local       reads ust_staging.stg_mentionlytics__mentions from
                        dev.duckdb, writes mention_enrichment.parquet. Needs
                        DATABRICKS_HOST + DATABRICKS_TOKEN (a PAT) for the endpoint.
  --backend databricks  reads ust_databricks.ust_staging.stg_mentionlytics__mentions,
                        writes ust_databricks.social.mention_enrichment (Delta).

Runs on Databricks as a **Python-script task** (spark_python_task) — no notebook:
  - Source: Git, path scripts/enrich_mentions.py; Parameters: --backend databricks
  - Dependent libraries (PyPI): anthropic, databricks-sdk
  - Auth is AMBIENT — the task's run-as identity supplies the serving token via
    databricks-sdk (no secret, no PAT, no env vars). The run-as user must have
    model-serving access. (Local runs still use DATABRICKS_HOST/DATABRICKS_TOKEN.)

Incremental, VERSION-AWARE, and BOUNDED. A mention counts as done if it is enriched
at the current model+prompt version, OR is enriched at all and sits outside the last
social_enrich_backfill_weeks weeks. So a normal run touches only new mentions; a
PROMPT_VERSION bump re-labels the recent window automatically (no manual truncate)
rather than the whole corpus — which matters, because the board ranks per calendar
week, so a stale label on a week nobody ranks any more changes no published number.
--backfill-weeks 0 re-labels all history. Staging keeps the latest enriched_at per
mention, so a re-labelled row supersedes the old one. A deterministic
pre-filter labels obvious gambling/betting spam first (is_spam, no LLM call), so
only the rest reach the model — see PREFILTER_SPAM_TERMS. Multi-label by design —
arrays, never a single category key.

Local smoke test (needs a Databricks PAT in env):
    python scripts/enrich_mentions.py --backend local --limit 10
    python scripts/enrich_mentions.py --backend local --dry-run   # build prompts only, no calls
    python scripts/enrich_mentions.py --backend databricks --backfill-weeks 8
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

import yaml

# ─────────────────────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────────────────────

def _find_dbt_project_path():
    """Locate dbt_project.yml. __file__ is NOT always defined — Databricks
    Python-script tasks exec() this in a notebook-style wrapper — so fall back to
    searching upward from the working directory. Same helper as the resolver."""
    candidates = []
    try:
        candidates.append(Path(__file__).resolve().parents[1] / "dbt_project.yml")
    except NameError:
        pass
    cur = Path.cwd()
    for _ in range(6):
        candidates.append(cur / "dbt_project.yml")
        if cur.parent == cur:
            break
        cur = cur.parent
    for c in candidates:
        if c.exists():
            return c
    return candidates[0] if candidates else Path("dbt_project.yml")


def _dbt_var(name, default):
    """Read a var from dbt_project.yml's vars: block, so this script and the models
    share one number instead of two that drift."""
    try:
        data = yaml.safe_load(_find_dbt_project_path().read_text(encoding="utf-8"))
        return data["vars"][name]
    except Exception:
        return default


MODEL = "databricks-claude-haiku-4-5"   # Databricks-hosted; billed via Databricks
PROMPT_VERSION = "v3"                    # bump when INSTRUCTIONS change (stored in model_version).
                                         # v2 = added mentioned_products (sellable-SKU signal).
                                         # v3 = several mentions per call (see MENTIONS_PER_CALL).
                                         #      Bumped even though the per-mention task is unchanged:
                                         #      the model now sees neighbouring posts in the same
                                         #      context, so a label is not guaranteed identical to what
                                         #      the one-at-a-time prompt produced. model_version has to
                                         #      say how a label was made.
                                         # A bump re-labels the recent window (see BACKFILL_WEEKS).
MAX_TOKENS_BASE = 400                    # envelope + slack
MAX_TOKENS_PER_MENTION = 260             # 4 arrays + 3 scalars comfortably fits
CONCURRENCY = 8                          # parallel serving calls — lower if you hit FMAPI rate limits
# Mentions per LLM call. The instruction block is ~900 tokens and used to be re-sent
# once per mention: at 12.8k mentions that is the bulk of the spend, and pure
# repetition. Ten per call cuts both the call count and the instruction cost ~10x
# (measured 2026-08-19: 900 mentions took 8 min one-at-a-time at concurrency 4, i.e.
# ~114 min for the full window).
# The risk this trades for that is LABEL BLEED — one post's dish attributed to its
# neighbour. Three guards: the prompt says to judge each mention independently, every
# result must carry back the id it was given, and any mention whose id does not come
# back is retried ON ITS OWN (a batch that misbehaves costs one retry, never a
# silently dropped or mislabelled row). Lower this if bleed shows up in spot checks;
# 1 restores exactly the old behaviour.
MENTIONS_PER_CALL = 10

# NOT ASKED FOR: sentiment. The workspace rate limit is on OUTPUT TOKENS per
# minute (observed 2026-08-19: HTTP 429 REQUEST_LIMIT_EXCEEDED at ~157 mentions/min),
# so every field costs throughput on every mention. Sentiment was out of scope for
# the trending board — it never entered trend_score or trend_rank, only a
# net_sentiment column that has now been dropped — and Mentionlytics already ships
# its own sentiment label per mention for free, kept on fct_social_mentions.
# PROMPT_VERSION deliberately NOT bumped for this: removing a field does not change
# how the remaining fields are labelled, and bumping would discard a backfill in
# flight to re-spend tokens for no quality gain. Force one with --backfill-weeks if
# you disagree.
MAX_RETRIES = 8                          # SDK-level retries: rides out 429s with backoff + retry-after
MAX_ATTEMPTS = 2                         # our own retries on bad/empty JSON
BATCH_SIZE = 300                         # write to the table every N classified (checkpoint / resumable)

# RE-LABEL WINDOW (#4 of the five social time windows — the set is defined in
# models/docs/_social_windows.md; read that before changing this).
# The answer to "must a prompt bump re-label all 15k mentions?".
# No. Every number the trending board publishes for a given week is computed from
# THAT WEEK's mentions alone (int_social_concept_trends ranks per calendar week), so
# labels only need to be current for the weeks still being ranked and compared.
# Older mentions keep whatever labels they already have: they stay in
# fct_social_mentions, keep feeding the dish class and the all-history channel
# medians, and simply lack any field a newer prompt added.
#
# So a version bump re-labels only the last social_enrich_backfill_weeks weeks
# instead of the entire corpus. Outside that window a mention counts as done if it
# has ANY enrichment at all.
#
# WEEK-ALIGNED, AND THAT MATTERS: the cutoff is a Monday, never a mid-week date. A
# PARTIALLY re-labelled week is the one genuinely broken state — mention_share's
# denominator is that week's labelled pairs, so if only a handful of a week's
# mentions carry a new array, those few become the entire universe for that week and
# their share reads ~1.0 with meaningless ranks. A wholly un-relabelled week is
# harmless by comparison: it just has no rows for the new field. This is also why
# --limit is a smoke-test tool only; it slices an arbitrary N mentions and will cut a
# week in half.
BACKFILL_WEEKS = _dbt_var("social_enrich_backfill_weeks", 4)

# Deterministic pre-filter (runs BEFORE the LLM). Obvious gambling/betting spam
# never appears in real food posts, so we label it here (is_spam=true) and SKIP
# the LLM call entirely. Validated on real data 2026-07 at ~99.7% precision (1 food
# false-positive). Thai gambling spam is the bulk (~333 hits, ~6% of all mentions);
# Vietnamese gambling spam is tiny today (~5) but the terms are 100% precise, so
# they're included to future-proof. It only removes what's UNAMBIGUOUS — obfuscated
# spam (leetspeak/mixed-script) and generic non-food (travel, off-topic, author-name
# noise — heavy on the Vietnam side) are left to the LLM, whose judgment they need.
PREFILTER_VERSION = "prefilter/v1"
PREFILTER_SPAM_TERMS = [
    # --- Thai (the bulk) ---
    "สล็อต", "สล๊อต", "สล้อต", "สลอต",      # slot (+ tone-mark obfuscations)
    "บาคาร่า", "บาคาร่าสด", "คาสิโน",        # baccarat / casino
    "แทงบอล", "เว็บพนัน", "พนันออนไลน์",     # football betting / gambling site
    "เครดิตฟรี", "ไฮโล", "ยิงปลา",           # free credit / hi-lo / fish shooting
    "ป๊อกเด้ง", "เว็บตรง", "หวย", "เดิมพัน",  # pok deng / direct site / lottery / wager
    # --- Vietnamese (rare today; 100% precise) ---
    "nhà cái", "cá cược", "nổ hũ", "tài xỉu",   # bookmaker / betting / jackpot-slots / sic-bo
    "đá gà", "lô đề", "game bài", "xóc đĩa", "soi cầu",  # cockfight / lottery / card games / prediction
    # --- brands / English (both markets) ---
    "casino", "baccarat", "sportsbook", "ufabet", "sbobet", "1xbet", "pgslot",
    "w88", "fun88", "789bet",
]
_PREFILTER_LC = [t.lower() for t in PREFILTER_SPAM_TERMS]

# The LLM reads the dbt-built staging model — the single source of dedup + clean
# truth — NOT the raw source. dbt must build stg_mentionlytics__mentions first, so
# the LLM only ever sees one deduped, typed row per mention (mention_id already
# bigint, matching the enrichment key — no re-dedup in this script, no type drift).
LOCAL_DUCKDB_PATH = "dev.duckdb"
DUCKDB_MENTIONS_REL = "ust_staging.stg_mentionlytics__mentions"
DBX_MENTIONS_REL = "ust_databricks.ust_staging.stg_mentionlytics__mentions"
LOCAL_ENRICHMENT_PATH = "data/mock/mentionlytics/mention_enrichment.parquet"
DBX_ENRICHMENT_TABLE = "ust_databricks.social.mention_enrichment"

# Prompt-for-JSON: the exact object shape is described here (no output_config).
# Arrays are multi-label (empty = none); confidence is 0.0–1.0.
INSTRUCTIONS = """You classify social-listening mentions captured for Thai and \
Vietnamese food & beverage market research. Read the mention's title and content \
and extract structured attributes.

You are given a NUMBERED LIST of mentions. Judge each one INDEPENDENTLY — a mention \
is labelled from its own title and content ONLY. Never let one mention's dishes, \
products, brands or sentiment leak into another's, even when they sit next to each \
other and look related: they are unrelated posts that merely share one request.

Respond with ONLY a single JSON object — no markdown, no code fence, no prose:

{"results": [ ...one entry per mention, in the order given... ]}

Every entry MUST carry back the "id" it was given, exactly one entry per id — none \
missing, no extras, no invented ids. Each entry has exactly these keys:
{
  "id": number,                  // the mention's id, copied EXACTLY from the input
  "is_food_relevant": boolean,   // true only if genuinely about food or beverages
  "is_spam": boolean,            // gambling/casino promos (e.g. 789BET), unrelated ads, bots
  "themes": [string],            // broad topics: "street food", "dessert", "coffee", "restaurant review"...
  "mentioned_dishes": [string],  // specific dishes: "banh khot", "pho", "mango sticky rice"...
  "mentioned_products": [string],// SELLABLE PRODUCTS — see the rule below
  "ingredients": [string],       // notable ingredients: "fish sauce", "coconut milk"...
  "brands": [string],            // brand / restaurant / product names
  "confidence": number           // 0.0–1.0, your overall certainty for THIS mention
}

mentioned_products — THE RULE THAT MATTERS MOST HERE. This is the only array a \
food DISTRIBUTOR can act on, so it is deliberately narrow: a product a grocery \
store or a restaurant could ORDER AS A LINE ITEM. Something with a brand, or a \
packaged / processed / prepared form. It is NOT the same as `ingredients`, which \
stays a loose list of whatever the post mentions.

  IN  — "Tiparos fish sauce", "Nongshim shin ramyun" (brand + product)
      — "canned coconut milk", "frozen spring rolls", "dried rice noodles",
        "instant noodles", "tom yum paste", "fish sauce", "condensed milk",
        "matcha powder" (packaged / processed goods, brand or not)
  OUT — "durian", "matcha", "pork", "lemon", "garlic", "shrimp" (RAW COMMODITY or
        produce — an ingredient, not something ordered as a SKU. These go in
        `ingredients`, not here.)
      — "som tam", "pho", "matcha latte" (a DISH or a prepared menu item — these
        go in `mentioned_dishes`)
      — "dessert", "noodles", "seafood" (a CATEGORY, too broad to order)
      — "7-Eleven", "Grab", "LINE MAN" (a retailer or delivery platform — `brands`)
      — a restaurant, a cafe, a reviewer, an influencer (`brands`)

If in doubt, LEAVE IT OUT. An empty mentioned_products is the normal, correct \
answer for most posts — people usually talk about dishes, not SKUs — and a \
commodity misfiled here pollutes the one signal a buyer reads. The word only \
belongs here if you could picture it on a shelf or an invoice as a distinct \
product. A product still goes here when its brand is unnamed; put the brand in \
`brands` when it IS named, and the product in both places is correct \
("Tiparos fish sauce" -> mentioned_products; "Tiparos" -> brands).

Rules: extract MULTIPLE labels where they apply — a post can mention several \
dishes, products, ingredients, and brands, and the same post can populate all \
four. Use empty arrays when none apply; never force a single category. is_spam is \
true for gambling/ads/bots regardless of food keywords present. Content may be \
Thai, Vietnamese, English, or other languages — judge on meaning, not keywords: \
a Thai or Vietnamese product name belongs in mentioned_products in its own script, \
exactly as written."""

_REQUIRED_KEYS = {
    "is_food_relevant", "is_spam", "themes", "mentioned_dishes",
    "mentioned_products", "ingredients", "brands", "confidence",
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

_MENTION_COLS = "mention_id, channel, tracker, keyword, title, content, posted_at"


def _backfill_cutoff_sql(weeks):
    """Monday of the week `weeks-1` weeks before the newest mention's week, as a SQL
    scalar. WEEK-ALIGNED by construction (date_trunc), so the window can never cut a
    week in half — see BACKFILL_WEEKS for why that is the one thing that matters."""
    return (f"(select date_add(cast(date_trunc('week', max(posted_at)) as date), "
            f"-7 * {int(weeks) - 1}) from {{rel}})")


def read_mentions_and_enriched(backend, limit, duckdb_path, backfill_weeks=None):
    """Return (list of mention dicts to classify, count already done).

    Reads the deduped, cleaned dbt staging model (stg_mentionlytics__mentions) — one
    typed row per mention_id — so the LLM never sees duplicates or raw junk, and the
    dedup/clean logic lives in exactly one place (dbt), not re-implemented here.

    A mention counts as DONE when either:
      * it is enriched at the CURRENT model+prompt version (or by the current
        deterministic prefilter) — the normal incremental case; or
      * it is enriched at ANY version AND sits OUTSIDE the last `backfill_weeks`
        weeks — the cost control. Ranking is per calendar week, so a stale label on a
        week nobody ranks any more changes no published number.
    Together: a PROMPT_VERSION bump re-labels the recent window automatically (no
    manual truncate, no flag to remember) without dragging the whole corpus back
    through the model. Pass backfill_weeks=0 to re-label all history.

    Staging keeps the latest enriched_at per mention, so a re-labelled row supersedes
    the old one."""
    weeks = BACKFILL_WEEKS if backfill_weeks is None else backfill_weeks
    versions = _current_versions()
    in_list = ", ".join(f"'{v}'" for v in sorted(versions))
    if backend == "databricks":
        spark = _get_spark()
        rows = [r.asDict() for r in
                spark.sql(f"select {_MENTION_COLS} from {DBX_MENTIONS_REL}").collect()]
        try:
            enriched_ids = {r.mention_id for r in spark.sql(
                f"select mention_id from {DBX_ENRICHMENT_TABLE} "
                f"where model_version in ({in_list})").collect()}
            if weeks and int(weeks) > 0:
                cutoff = _backfill_cutoff_sql(weeks).format(rel=DBX_MENTIONS_REL)
                enriched_ids |= {r.mention_id for r in spark.sql(
                    f"select e.mention_id from {DBX_ENRICHMENT_TABLE} e "
                    f"join {DBX_MENTIONS_REL} m on m.mention_id = e.mention_id "
                    f"where cast(m.posted_at as date) < {cutoff}").collect()}
        except Exception:
            enriched_ids = set()
    else:
        import duckdb
        con = duckdb.connect(duckdb_path, read_only=True)
        rows = con.sql(f"select {_MENTION_COLS} from {DUCKDB_MENTIONS_REL}").df().to_dict("records")
        con.close()
        try:
            con2 = duckdb.connect(duckdb_path, read_only=True)
            enriched_ids = set(con2.sql(
                f"select mention_id from read_parquet('{LOCAL_ENRICHMENT_PATH}') "
                f"where model_version in ({in_list})"
            ).df()["mention_id"].tolist())
            if weeks and int(weeks) > 0:
                cutoff = _backfill_cutoff_sql(weeks).format(rel=DUCKDB_MENTIONS_REL)
                enriched_ids |= set(con2.sql(
                    f"select e.mention_id from read_parquet('{LOCAL_ENRICHMENT_PATH}') e "
                    f"join {DUCKDB_MENTIONS_REL} m on m.mention_id = e.mention_id "
                    f"where cast(m.posted_at as date) < {cutoff}"
                ).df()["mention_id"].tolist())
            con2.close()
        except Exception:
            enriched_ids = set()

    new = [r for r in rows
           if r["mention_id"] is not None and r["mention_id"] not in enriched_ids]
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
        StructField("mentioned_products", arr),
        StructField("ingredients", arr),
        StructField("brands", arr),
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

def _current_versions():
    """Version strings that mean "already done at today's logic". Both are
    included: PREFILTER_VERSION rows were never sent to the model (deterministic
    gambling spam), so an LLM-version bump must NOT drag them back through the
    pipeline — they have empty arrays by definition and fct_social_mentions filters
    them out anyway. Bump PREFILTER_VERSION when the term list changes and they
    re-run instead."""
    return {f"{MODEL}/{PROMPT_VERSION}", PREFILTER_VERSION}


def is_prefilter_spam(m):
    """True when the caption contains an unambiguous gambling/betting term — safe
    to label spam without asking the LLM."""
    text = f"{m.get('title') or ''} {m.get('content') or ''}".lower()
    return any(term in text for term in _PREFILTER_LC)


def prefilter_record(m, enriched_at):
    """A deterministic enrichment row for pre-filtered spam (no LLM). Same shape as
    to_records() so it filters out downstream exactly like an LLM spam call."""
    return {
        "mention_id": int(m["mention_id"]),
        "is_food_relevant": False,
        "is_spam": True,
        "themes": [], "mentioned_dishes": [], "mentioned_products": [],
        "ingredients": [], "brands": [],
        "confidence": 1.0,
        "enriched_at": enriched_at,
        "model_version": PREFILTER_VERSION,
    }


def build_user_prompt(mentions):
    """Render a batch. Each mention is fenced and id-labelled, so the model can carry
    its id back and so two posts can't be read as one run of text."""
    parts = [f"{len(mentions)} mentions follow. Return exactly {len(mentions)} "
             f"results, one per id."]
    for m in mentions:
        parts.append(
            f"--- mention id: {int(m['mention_id'])} ---\n"
            f"Channel: {m.get('channel')}\n"
            f"Tracker: {m.get('tracker')}\n"
            f"Keyword: {m.get('keyword')}\n"
            f"Title: {m.get('title')}\n"
            f"Content: {m.get('content')}"
        )
    return "\n\n".join(parts)


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


def classify_call(client, mentions):
    """ONE call covering `mentions`. Returns {mention_id: attributes} for entries that
    came back valid AND matched an id we sent. Anything else is simply absent, and the
    caller retries those on their own.

    Ids are VALIDATED, not trusted. The whole premise of batching is that several
    unrelated posts share one context, so a result that can't be tied back to the
    exact mention it describes is worse than no result — it would attach one post's
    dishes to another and there would be no trace of it."""
    wanted = {int(m["mention_id"]) for m in mentions}
    max_tokens = MAX_TOKENS_BASE + MAX_TOKENS_PER_MENTION * len(mentions)
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            resp = client.messages.create(
                model=MODEL,
                max_tokens=max_tokens,
                # cached: the instruction block is byte-identical on every call and is
                # the largest part of the input (the resolver caches its catalog the
                # same way; whether the serving proxy honours it is reported below)
                system=[{"type": "text", "text": INSTRUCTIONS,
                         "cache_control": {"type": "ephemeral"}}],
                messages=[{"role": "user", "content": build_user_prompt(mentions)}],
            )
            text = next((b.text for b in resp.content if b.type == "text"), "")
            data = extract_json(text)
            results = (data or {}).get("results")
            if not isinstance(results, list):
                continue
            out = {}
            for r in results:
                if not isinstance(r, dict) or not _REQUIRED_KEYS.issubset(r):
                    continue
                try:
                    mid = int(r["id"])
                except (KeyError, TypeError, ValueError):
                    continue
                if mid in wanted:          # never accept an id we didn't ask about
                    out[mid] = r
            if out:
                return out
        except Exception as e:  # transient serving error, rate limit, etc.
            if attempt == MAX_ATTEMPTS:
                ids = ",".join(str(i) for i in sorted(wanted)[:5])
                print(f"  WARN batch [{ids}...] x{len(wanted)}: {e}", file=sys.stderr)
    return {}


def classify_batch(client, mentions, concurrency, per_call=None):
    """Classify `mentions`, several per call, concurrently.

    TWO PASSES: batched, then one-at-a-time for whatever didn't come back. The second
    pass is what makes batching safe — a call that returns short, drops an id or
    invents one costs a few single retries instead of losing rows."""
    per_call = MENTIONS_PER_CALL if per_call is None else max(1, int(per_call))
    chunks = [mentions[i:i + per_call] for i in range(0, len(mentions), per_call)]
    out = {}
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        for res in pool.map(lambda c: classify_call(client, c), chunks):
            out.update(res)

    missing = [m for m in mentions if int(m["mention_id"]) not in out]
    if missing and per_call > 1:
        print(f"  {len(missing)}/{len(mentions)} not returned by their batch — "
              f"retrying individually")
        with ThreadPoolExecutor(max_workers=concurrency) as pool:
            for res in pool.map(lambda m: classify_call(client, [m]), missing):
                out.update(res)
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
            "mentioned_products": list(a["mentioned_products"]),
            "ingredients": list(a["ingredients"]),
            "brands": list(a["brands"]),
            "confidence": float(a["confidence"]),
            "enriched_at": enriched_at,
            "model_version": model_version,
        })
    return records


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def main(backend="local", limit=None, dry_run=False, concurrency=CONCURRENCY,
         duckdb_path=LOCAL_DUCKDB_PATH, backfill_weeks=None, per_call=None):
    per_call = MENTIONS_PER_CALL if per_call is None else max(1, int(per_call))
    weeks = BACKFILL_WEEKS if backfill_weeks is None else backfill_weeks
    print(f"re-label window: "
          + (f"last {weeks} weeks (older mentions keep their existing labels)"
             if weeks and int(weeks) > 0 else "ALL history"))
    mentions, n_enriched = read_mentions_and_enriched(backend, limit, duckdb_path, weeks)

    # deterministic pre-filter: label obvious gambling spam without the LLM
    spam = [m for m in mentions if is_prefilter_spam(m)]
    todo = [m for m in mentions if not is_prefilter_spam(m)]
    print(f"{n_enriched} already enriched; {len(mentions)} new "
          f"({len(spam)} pre-filtered as spam, {len(todo)} to the LLM)")
    if not mentions:
        print("nothing to do.")
        return

    if dry_run:
        print(f"[dry-run] would pre-filter {len(spam)} spam and classify {len(todo)} "
              f"with {MODEL}.")
        if todo:
            print(f"First LLM prompt ({min(MENTIONS_PER_CALL, len(todo))} mentions "
                  f"per call):\n")
            print(build_user_prompt(todo[:MENTIONS_PER_CALL]))
        return

    # write the deterministic spam labels first (no LLM, checkpointed)
    if spam:
        write_enrichment(backend, [prefilter_record(m, datetime.now(timezone.utc))
                                   for m in spam])
        print(f"  pre-filtered {len(spam)} gambling/spam mentions (no LLM call)")

    total = len(todo)
    written = 0
    # Process in batches and WRITE each batch — checkpoints progress so nothing is
    # lost if the run is interrupted, and a re-run resumes (incremental read skips
    # what's already written).
    client = get_client(backend) if todo else None
    print(f"  {per_call} mentions per LLM call, {concurrency} calls in flight "
          f"=> ~{-(-total // per_call)} calls for {total} mentions")
    for start in range(0, total, BATCH_SIZE):
        chunk = todo[start:start + BATCH_SIZE]
        attrs = classify_batch(client, chunk, concurrency, per_call)
        write_enrichment(backend, to_records(attrs, datetime.now(timezone.utc)))
        written += len(attrs)
        print(f"  checkpoint {start // BATCH_SIZE + 1}: wrote {len(attrs)}/{len(chunk)} "
              f"(cumulative {written}/{total})")

    failed = total - written
    print(f"DONE. pre-filtered {len(spam)} spam + wrote {written} LLM rows"
          + (f"; {failed} failed — re-run to backfill (incremental)" if failed else ""))


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--backend", choices=["local", "databricks"], default="local")
    p.add_argument("--limit", type=int,
                   help="classify at most N mentions. SMOKE TEST ONLY: it slices an "
                        "arbitrary N and will cut a week in half, which breaks that "
                        "week's mention_share. Use --backfill-weeks to scope a real run.")
    p.add_argument("--mentions-per-call", type=int, default=None,
                   help=f"mentions sent in one LLM call (default {MENTIONS_PER_CALL}). "
                        f"Higher = fewer calls and less repeated instruction text, but "
                        f"more room for label bleed between posts; 1 restores "
                        f"one-at-a-time.")
    p.add_argument("--backfill-weeks", type=int, default=None,
                   help=f"on a PROMPT_VERSION bump, re-label only the last N weeks "
                        f"(default {BACKFILL_WEEKS}, from dbt_project.yml's "
                        f"social_enrich_backfill_weeks). Week-aligned. 0 = all history.")
    p.add_argument("--concurrency", type=int, default=CONCURRENCY,
                   help=f"parallel serving calls (default {CONCURRENCY}); lower if rate-limited")
    p.add_argument("--dry-run", action="store_true", help="build prompts only; no API call")
    p.add_argument("--duckdb", default=LOCAL_DUCKDB_PATH,
                   help=f"local duckdb build path (default {LOCAL_DUCKDB_PATH})")
    args = p.parse_args()
    try:
        sys.stdout.reconfigure(encoding="utf-8")  # mentions carry Thai/Vietnamese text
    except Exception:
        pass
    main(backend=args.backend, limit=args.limit, dry_run=args.dry_run,
         concurrency=args.concurrency, duckdb_path=args.duckdb,
         backfill_weeks=args.backfill_weeks, per_call=args.mentions_per_call)
