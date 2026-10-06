"""Map every extracted dish / product name to ONE canonical product (social step ②b).

The enrichment names the same thing many ways — "ไอติมเลย์", "lays ice cream",
"ไอศกรีมเลย์", "lay's ice cream" — and on BOTH boards (some posts' labels put it under
dishes, some under products). Ranked separately, one viral product becomes a dozen
small ones and none of them stays on the board (measured 2026-10-05: Lay's ice cream
was split across 9+ names; the July sponge-cake spike sat on the dish board at #204).

This script asks the Databricks-hosted model, in batches, for each NAME's standard
English product name and an item / dish vote, and stores the answer once per name in
the concept_canon landing table. int_social_concept_canon then turns those answers into
one product per merged name — one key, one display name, one board, decided across all
of the product's spellings — and int_social_concept_trends counts posts per PRODUCT.
dbt itself never calls the LLM.

  * ALL HISTORY, not the board's 13 weeks: promo matching reads all history, and a name
    first seen five months ago must map to the same product as today's.
  * EACH NAME ONCE. A canonicalised name is never re-asked (until PROMPT_VERSION
    changes), so its product cannot drift from run to run.
  * STABLE NAMES. Names go most-posted first, in waves; every batch is shown the product
    names already chosen and told to reuse one when it is the same thing, so next
    week's new spelling joins "lay's ice cream" instead of founding "lay's potato chip
    ice cream".

PHASE 2, --profile-products: every PRODUCT (all of them, not just the board's — promo
matching must find a product that never trended) is labelled once:
    product_type  branded  names a brand or maker            (lay's ice cream, tiparos fish sauce)
                  shelf    a specific ready-made product sold in stores, brand or not
                           (lemon jelly sponge cake, hokkaido milk ice cream)
                  generic  a category, a commodity or a dish   (fish sauce, ice cream, som tam)
    brand         the brand, when there is one — the hook promo matching links on.
Variant detail ("which Pepsi? which Magnum?") is NOT asked of the LLM: on a 300-product
trial it grouped one family several ways depending only on batch order. It is derived
in dbt instead, deterministically — int_social_product_variants lists a product's
related products (same brand, or a longer name containing its whole name).
int_social_trend_board ranks branded + shelf products on their own board, AHEAD of the
generic categories, so a staple can never outrank a product someone can stock.
Phase 2 reads the products from int_social_concept_canon — the product key is computed
in ONE place, in SQL — so dbt must rebuild that model between the two phases.

PHASE 1b, --consolidate: the LLM names one product slightly differently in different
batches ("scotch brite cake" / "scotch-brite sponge cake"; measured 2026-10-06 on the
7-Eleven lemon jelly sponge cake). Products with enough posts whose names share most of
their words are sent in small groups with "which of these are the SAME product?", and
every spelling of a duplicate is re-pointed to the surviving product's name — written
as a newer row in concept_canon, so nothing downstream changes shape. Same words in a
different order need no LLM at all: int_social_concept_canon merges those itself.

ORDER MATTERS. Weekly job: parse -> enrich -> dbt (to int_social_concept_mentions) ->
THIS (names) -> dbt (int_social_concept_canon) -> THIS --consolidate ->
dbt (int_social_concept_canon) -> THIS --profile-products -> dbt (trends, board) ->
resolve -> dbt (rest).

    python scripts/canonicalize_concepts.py --init              # create the empty landing tables
    python scripts/canonicalize_concepts.py --dry-run           # count names to do, no LLM
    python scripts/canonicalize_concepts.py                     # phase 1: canonicalise new names
    python scripts/canonicalize_concepts.py --consolidate       # phase 1b: merge near-duplicate products
    python scripts/canonicalize_concepts.py --profile-products  # phase 2: label new products
    python scripts/canonicalize_concepts.py --backend databricks [--profile-products]

Local runs authenticate to model serving with DATABRICKS_SERVING_TOKEN if set, else a
browser sign-in (the everyday DATABRICKS_TOKEN PAT is SQL-only and is refused by model
serving). On Databricks, auth is the job's run-as identity.
"""

from __future__ import annotations

import argparse
import difflib
import os
import re
import sys
import time
import unicodedata
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

MODEL = "databricks-claude-sonnet-5"
PROMPT_VERSION = "v1"
BATCH_SIZE = 60          # names per call: a 60-line reply fits comfortably in max_tokens
CONCURRENCY = 6
WAVE_BATCHES = CONCURRENCY * 2   # batches per wave; hints refresh between waves
HINT_LIMIT = 250         # existing product names shown per call, most-posted first
MAX_TOKENS = 6000

LOCAL_DUCKDB_PATH = "dev.duckdb"
LOCAL_CANON_PATH = "data/mock/mentionlytics/concept_canon.parquet"
DUCKDB_NAMES_REL = "ust_intermediate.int_social_concept_mentions"
DBX_NAMES_REL = "ust_databricks.ust_intermediate.int_social_concept_mentions"
DBX_CANON_TABLE = "ust_databricks.social.concept_canon"
DATABRICKS_HOST = os.environ.get("DATABRICKS_HOST", "adb-7405618436278207.7.azuredatabricks.net") \
    .replace("https://", "").rstrip("/")
COLUMNS = ["concept_class", "concept_norm", "concept_text", "canonical_name",
           "canonical_class", "canonicalized_at", "model_version"]

CONSOLIDATE_MIN_POSTS = 3       # products below this are not worth an LLM look
CONSOLIDATE_CLUSTER_MAX = 15    # names per question; larger families are cut to their top
CONSOLIDATE_PER_CALL = 12       # clusters per LLM call
# Consolidation remembers where it got to: every run appends a CHECKPOINT row to
# concept_canon (class '__checkpoint__', no canonical_name, so staging drops it) and the
# next run only asks about groups holding a name first canonicalised after the latest
# checkpoint. The checkpoint travels with the table, so a bootstrap upload carries it too.
CHECKPOINT_CLASS, CHECKPOINT_NAME = "__checkpoint__", "consolidate"
STOPWORDS = {"a", "an", "and", "the", "of", "with", "in", "on", "style", "flavor",
             "flavour", "flavored", "flavoured", "made", "homemade"}

CONSOLIDATE_INSTRUCTIONS = """You merge duplicate product names from a food social-listening feed. Each numbered GROUP lists names that look alike. Within a group, say which names are the SAME product: the same brand, the same thing, the same flavour or variant, written differently.

Different flavours, different variants, different sizes of a different product, a brand vs one of its products, or a dish vs a packaged product are NOT the same. When in doubt, do not merge.

Reply with one line per set of duplicates and nothing else, TAB-separated:
<group number>\t<comma-separated item numbers that are the same product>
A name with no duplicate gets no line. A group with no duplicates gets no line."""

PROFILE_VERSION = "v2"           # v2 = stricter shelf rule (a cafe / homemade dessert is generic)
PROFILE_BATCH_SIZE = 100
LOCAL_PROFILE_PATH = "data/mock/mentionlytics/product_profile.parquet"
DBX_PROFILE_TABLE = "ust_databricks.social.product_profile"
DUCKDB_CANON_REL = "ust_intermediate.int_social_concept_canon"
DBX_CANON_REL = "ust_databricks.ust_intermediate.int_social_concept_canon"
PROFILE_COLUMNS = ["product_key", "product_name", "product_type", "brand", "profiled_at",
                   "model_version"]

PROFILE_INSTRUCTIONS = """You label food products mentioned on Thai and Vietnamese social media, for a distributor deciding what it could stock.

Each input line is: <index>. [<dish or item>] <product name> | spellings seen: <a few original spellings>

For each product give:
1. type:
   - "branded": it names a specific brand or manufacturer (lay's ice cream, tiparos fish sauce, mama tom yum noodles, deedo cantaloupe juice, 7-eleven onigiri).
   - "shelf": a specific ready-made product SOLD IN SHOPS or convenience stores - packaged, bottled, frozen or a bakery product - even when no brand is named (lemon jelly sponge cake, hokkaido milk ice cream, salted egg potato chips, crispy pork skin snack).
   - "generic": a broad category or commodity (fish sauce, ice cream, coffee, snacks, instant noodles, matcha, rice paper), OR a dish or dessert made at home or served at a restaurant or cafe (som tam, pho, tiramisu, sponge cake, banh mi). A dessert counts as shelf only when the name says it is a packaged or store product ("7-eleven tiramisu cup").
2. brand: the brand name when type is branded, otherwise "-".
Reply with one line per input and nothing else, TAB-separated, copying the product name exactly as given:
<index>\t<product name>\t<branded, shelf or generic>\t<brand or ->"""

INSTRUCTIONS = """You standardise the names of foods and food products taken from Thai and Vietnamese social media posts, so that every spelling of the SAME thing gets the SAME name.

Each input line is: <index>. [<board it came from: dish or item>] <name as written>

For each input give:
1. canonical: a short English name for the specific thing, lowercase.
   - Keep the brand when there is one ("lay's ice cream", "tiparos fish sauce").
   - Keep a flavour or variant when it makes it a different product ("lay's durian flavor" is not "lay's ice cream"); drop it only when it is packaging noise.
   - Translate Thai and Vietnamese. Use the most common English name, so variants converge: "ไอติมเลย์", "lays ice cream" and "ไอศกรีมเลย์" are all "lay's ice cream".
   - If a name in KNOWN PRODUCTS below is the same thing, reuse it EXACTLY as written.
2. category: "item" if it is a product someone buys ready-made (a packaged snack, branded drink, sauce, a bakery or convenience-store product); "dish" if it is cooked or prepared (a recipe, a restaurant or street-food dish). The board the name came from is a hint, not the answer.

Reply with one line per input and nothing else, TAB-separated, copying the input name exactly as given:
<index>\t<name as written>\t<canonical>\t<item or dish>"""


# ─────────────────────────────────────────────────────────────────────────────
# LLM client (Databricks-hosted Claude)
# ─────────────────────────────────────────────────────────────────────────────

def _bearer_token(backend: str) -> str:
    from databricks.sdk.core import Config
    if backend == "databricks":
        return Config().authenticate()["Authorization"].split(" ", 1)[1]
    if os.environ.get("DATABRICKS_SERVING_TOKEN"):
        return os.environ["DATABRICKS_SERVING_TOKEN"]
    saved = os.environ.pop("DATABRICKS_TOKEN", None)   # SQL-only PAT: refused by serving
    try:
        cfg = Config(host=f"https://{DATABRICKS_HOST}", auth_type="external-browser")
        return cfg.authenticate()["Authorization"].split(" ", 1)[1]
    finally:
        if saved is not None:
            os.environ["DATABRICKS_TOKEN"] = saved


def get_client(backend: str):
    import anthropic
    return anthropic.Anthropic(
        api_key="unused",
        base_url=f"https://{DATABRICKS_HOST}/serving-endpoints/anthropic",
        default_headers={"Authorization": f"Bearer {_bearer_token(backend)}"},
        # bounded: the SDK default (10-minute timeout x 8 retries) let one network drop
        # stall a wave for 73 minutes on 2026-10-06. A failed batch is retried next run.
        timeout=120.0,
        max_retries=4,
    )


# ─────────────────────────────────────────────────────────────────────────────
# Backend I/O
# ─────────────────────────────────────────────────────────────────────────────

def _spark():
    try:
        return spark  # noqa: F821 — global on Databricks
    except NameError:
        from pyspark.sql import SparkSession
        return SparkSession.builder.getOrCreate()


def _query(backend: str, sql: str, duckdb_path: str = LOCAL_DUCKDB_PATH) -> list[dict]:
    if backend == "databricks":
        return [r.asDict() for r in _spark().sql(sql).collect()]
    import duckdb
    con = duckdb.connect(duckdb_path, read_only=True)
    try:
        return con.sql(sql).df().to_dict("records")
    finally:
        con.close()


def init_landing(backend: str) -> None:
    """Create the empty landing tables so the dbt staging views can build before the
    first run (DuckDB binds read_parquet at view-creation time)."""
    for table, local, cols in ((DBX_CANON_TABLE, LOCAL_CANON_PATH, COLUMNS),
                               (DBX_PROFILE_TABLE, LOCAL_PROFILE_PATH, PROFILE_COLUMNS)):
        if backend == "databricks":
            ddl = ", ".join(f"`{c}` string" for c in cols)
            _spark().sql(f"create table if not exists {table} ({ddl}) using delta")
            continue
        import pandas as pd
        path = Path(local)
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            pd.DataFrame({c: pd.Series(dtype="string") for c in cols}).to_parquet(path, index=False)
            print(f"created empty {path}")


def read_names(backend: str) -> list[dict]:
    """Every (class, name) ever extracted, most-posted first."""
    rel = DBX_NAMES_REL if backend == "databricks" else DUCKDB_NAMES_REL
    return _query(backend, f"""
        select concept_class, concept_norm,
               min(concept_text)            as concept_text,
               count(distinct mention_id)   as posts
        from {rel}
        group by 1, 2
        order by posts desc, concept_norm
    """)


def read_done(backend: str) -> list[dict]:
    """Rows already canonicalised at the CURRENT prompt version."""
    version = f"%/{PROMPT_VERSION}"
    if backend == "databricks":
        return _query(backend, f"select concept_class, concept_norm, canonical_name from {DBX_CANON_TABLE} "
                               f"where model_version like '{version}'")
    import pandas as pd
    path = Path(LOCAL_CANON_PATH)
    if not path.exists():
        return []
    df = pd.read_parquet(path)
    df = df[df["model_version"].fillna("").str.endswith(f"/{PROMPT_VERSION}")]
    return df[["concept_class", "concept_norm", "canonical_name"]].to_dict("records")


MISALIGNED_SHARE = 0.25     # shifted batches measured 41-51% of names on a neighbour's
                            # answer; the worst healthy batch 9%


def read_misaligned(backend: str, posts_by_name: dict) -> set:
    """Names whose CURRENT answer came from a batch that was answered one line off.

    Before reply lines repeated their input name, an index-only reply could be numbered
    from 1 instead of 0; every name then took the answer meant for the name sent before
    it (2026-10-05: 3 batches, 177 names, e.g. "spicy beef noodle soup" -> "coffee
    beans"). A batch is rebuilt from its rows (one write timestamp each) and put back in
    the order it was sent — most-posted first, then by name — and judged shifted when
    many answers share a word with the PREVIOUS name but none with their own. Phase 1
    re-asks those names; the new answers are newer rows, so staging prefers them, and
    the next run finds nothing left to redo."""
    version = f"%/{PROMPT_VERSION}"
    if backend == "databricks":
        rows = _query(backend, f"select concept_class, concept_norm, concept_text, canonical_name, "
                               f"canonicalized_at from {DBX_CANON_TABLE} "
                               f"where model_version like '{version}' and canonical_name is not null")
    else:
        import pandas as pd
        path = Path(LOCAL_CANON_PATH)
        if not path.exists():
            return set()
        d = pd.read_parquet(path)
        d = d[d["model_version"].fillna("").str.endswith(f"/{PROMPT_VERSION}") & d["canonical_name"].notna()]
        rows = d.to_dict("records")
    words = lambda s: {w for w in re.findall(r"\w+", str(s or "").lower()) if len(w) > 2}
    latest, batches = {}, {}
    for r in rows:
        key, at = (r["concept_class"], r["concept_norm"]), str(r["canonicalized_at"] or "")
        if at >= latest.get(key, ""):
            latest[key] = at
        batches.setdefault(at, []).append(r)
    redo = set()
    for at, batch in batches.items():
        batch.sort(key=lambda r: (-posts_by_name.get((r["concept_class"], r["concept_norm"]), 0), r["concept_norm"]))
        sent = [words(r["concept_norm"]) | words(r["concept_text"]) for r in batch]
        shifted = sum(1 for i in range(1, len(batch))
                      if words(batch[i]["canonical_name"]) & sent[i - 1]
                      and not words(batch[i]["canonical_name"]) & sent[i])
        if len(batch) >= 10 and shifted / len(batch) >= MISALIGNED_SHARE:
            redo |= {(r["concept_class"], r["concept_norm"]) for r in batch
                     if latest[(r["concept_class"], r["concept_norm"])] == at}
    return redo


def write(backend: str, records: list[dict], table: str = DBX_CANON_TABLE,
          local: str = LOCAL_CANON_PATH, columns: list = None) -> None:
    columns = columns or COLUMNS
    if not records:
        return
    rows = [{c: (None if r.get(c) is None else str(r[c])) for c in columns} for r in records]
    if backend == "databricks":
        from pyspark.sql.types import StructType, StructField, StringType
        schema = StructType([StructField(c, StringType(), True) for c in columns])
        (_spark().createDataFrame(rows, schema=schema).write.format("delta")
            .mode("append").option("mergeSchema", "true").saveAsTable(table))
        return
    import pandas as pd
    path = Path(local)
    df = pd.DataFrame(rows, columns=columns)
    if path.exists():
        df = pd.concat([pd.read_parquet(path), df], ignore_index=True)
    df.to_parquet(path, index=False)


# ─────────────────────────────────────────────────────────────────────────────
# Canonicalise
# ─────────────────────────────────────────────────────────────────────────────

_LINE = re.compile(r"^\s*(\d+)\.?\s*\t\s*(.*?)\s*\t\s*(.+?)\s*\t\s*(item|dish)\s*$", re.IGNORECASE)


def _fold_echo(s: str) -> str:
    """Letters and digits only, accents and Thai marks dropped — for comparing a name
    the model copied back with the name that was sent."""
    s = unicodedata.normalize("NFKD", str(s or "").lower())
    return "".join(ch for ch in s if ch.isalnum() and not unicodedata.combining(ch))


def echo_matches(echo: str, sent: str) -> bool:
    """Does the name the model copied back belong to THIS input line? Every reply line
    repeats its input name because the index alone is not trustworthy: on 2026-10-05
    three 60-name batches came back numbered from 1 instead of 0, and every name took
    its neighbour's answer ("sprite" -> "spicy short rib pho")."""
    a, b = _fold_echo(echo), _fold_echo(sent)
    if not a or not b:
        return False
    return a == b or difflib.SequenceMatcher(None, a, b).ratio() >= 0.8


def parse_reply(text: str, sent: list[str]) -> dict[int, tuple[str, str]]:
    """TAB-separated lines -> {index: (canonical, category)}. A line that does not
    parse, or whose copied name is not the name sent at that index, is simply
    missing, and its name is retried next run."""
    out = {}
    for line in (text or "").splitlines():
        m = _LINE.match(line)
        if m and int(m.group(1)) < len(sent) and echo_matches(m.group(2), sent[int(m.group(1))]):
            name = m.group(3).strip().strip('"').lower()
            if name:
                out[int(m.group(1))] = (name, m.group(4).lower())
    return out


def canonicalize_batch(client, model: str, batch: list[dict], hints: list[str]) -> list[dict]:
    sent = [r["concept_text"] or r["concept_norm"] for r in batch]
    lines = "\n".join(f"{i}. [{r['concept_class']}] {s}" for i, (r, s) in enumerate(zip(batch, sent)))
    known = "KNOWN PRODUCTS:\n" + ("\n".join(hints) if hints else "(none yet)")
    parsed = {}
    for _ in range(2):          # one retry for a reply that came back short or garbled
        resp = client.messages.create(
            model=model, max_tokens=MAX_TOKENS, system=INSTRUCTIONS,
            messages=[{"role": "user", "content": f"{known}\n\nINPUT:\n{lines}"}])
        parsed = parse_reply("".join(getattr(b, "text", "") for b in resp.content), sent)
        if len(parsed) >= len(batch) * 0.9:
            break
    now = datetime.now(timezone.utc).replace(tzinfo=None).isoformat(sep=" ", timespec="seconds")
    return [{"concept_class": r["concept_class"], "concept_norm": r["concept_norm"],
             "concept_text": r["concept_text"], "canonical_name": parsed[i][0],
             "canonical_class": parsed[i][1], "canonicalized_at": now,
             "model_version": f"{model}/{PROMPT_VERSION}"}
            for i, r in enumerate(batch) if i in parsed]


def top_hints(done: list[dict], posts_by_name: dict, limit: int = HINT_LIMIT) -> list[str]:
    """The most-posted product names chosen so far — what a new spelling should reuse."""
    weight = {}
    for r in done:
        w = posts_by_name.get((r["concept_class"], r["concept_norm"]), 0)
        weight[r["canonical_name"]] = weight.get(r["canonical_name"], 0) + w
    return [n for n, _ in sorted(weight.items(), key=lambda kv: -kv[1])[:limit]]


# ─────────────────────────────────────────────────────────────────────────────
# Phase 1b: merge near-duplicate products
# ─────────────────────────────────────────────────────────────────────────────

def _words(key: str) -> frozenset:
    return frozenset(w for w in (key or "").split() if w not in STOPWORDS and len(w) > 1)


def consolidation_clusters(products: list) -> list:
    """Groups of products whose names share most of their words: overlap coefficient
    |A & B| / min(|A|, |B|) >= 2/3 with at least two shared words. STAR-shaped, not
    chained: going most-posted first, a product groups only with names that overlap IT
    directly. Chaining (union-find) linked "banh mi" to "fish sauce" through a dozen
    intermediate names and produced one meaningless 15-name group (2026-10-06)."""
    words = [_words(p["product_key"]) for p in products]
    index = {}
    for i, ws in enumerate(words):
        for w in ws:
            index.setdefault(w, []).append(i)
    order = sorted(range(len(products)), key=lambda i: -products[i]["posts"])
    taken, clusters = set(), []
    for i in order:
        if i in taken or len(words[i]) < 2:
            continue
        near = set()
        for w in words[i]:
            for j in index[w]:
                if j == i or j in taken:
                    continue
                shared = len(words[i] & words[j])
                if shared >= 2 and shared / min(len(words[i]), len(words[j])) >= 2 / 3:
                    near.add(j)
        if near:
            members = [i] + sorted(near, key=lambda j: -products[j]["posts"])[:CONSOLIDATE_CLUSTER_MAX - 1]
            taken.update(members)
            clusters.append([products[m] for m in members])
    return clusters


def read_first_seen(backend: str) -> dict:
    """(class, name) -> when it was FIRST canonicalised, from the landing table's full
    history (staging keeps only the latest row, which a consolidation rewrites)."""
    if backend == "databricks":
        rows = _query(backend, f"select concept_class, concept_norm, min(canonicalized_at) as first_at "
                               f"from {DBX_CANON_TABLE} group by 1, 2")
    else:
        import pandas as pd
        path = Path(LOCAL_CANON_PATH)
        if not path.exists():
            return {}
        d = pd.read_parquet(path, columns=["concept_class", "concept_norm", "canonicalized_at"])
        rows = d.groupby(["concept_class", "concept_norm"], as_index=False)["canonicalized_at"].min() \
                .rename(columns={"canonicalized_at": "first_at"}).to_dict("records")
    return {(r["concept_class"], r["concept_norm"]): str(r["first_at"] or "") for r in rows
            if r["concept_class"] != CHECKPOINT_CLASS}


def last_checkpoint(backend: str) -> str:
    """When consolidation last finished ('' = never)."""
    if backend == "databricks":
        rows = _query(backend, f"select max(canonicalized_at) as at from {DBX_CANON_TABLE} "
                               f"where concept_class = '{CHECKPOINT_CLASS}'")
        return str(rows[0]["at"] or "") if rows else ""
    import pandas as pd
    path = Path(LOCAL_CANON_PATH)
    if not path.exists():
        return ""
    d = pd.read_parquet(path, columns=["concept_class", "canonicalized_at"])
    d = d[d["concept_class"] == CHECKPOINT_CLASS]
    return str(d["canonicalized_at"].max()) if len(d) else ""


def write_checkpoint(backend: str, model: str) -> None:
    now = datetime.now(timezone.utc).replace(tzinfo=None).isoformat(sep=" ", timespec="seconds")
    write(backend, [{"concept_class": CHECKPOINT_CLASS, "concept_norm": CHECKPOINT_NAME,
                     "concept_text": None, "canonical_name": None, "canonical_class": None,
                     "canonicalized_at": now, "model_version": f"{model}/{PROMPT_VERSION}"}])


def read_product_names(backend: str) -> list:
    """Products with their spellings (every (class, name) row) and post counts."""
    rel = DBX_CANON_REL if backend == "databricks" else DUCKDB_CANON_REL
    rows = _query(backend, f"""
        select c.product_key, c.product_name, c.product_class, c.product_mentions,
               c.concept_class, c.concept_norm, s.concept_text, s.canonical_class
        from {rel} as c
        left join {('ust_databricks.ust_staging' if backend == 'databricks' else 'ust_staging')}.stg_mentionlytics__concept_canon as s
            on s.concept_class = c.concept_class and s.concept_norm = c.concept_norm
    """)
    products = {}
    for r in rows:
        p = products.setdefault(r["product_key"], {
            "product_key": r["product_key"], "product_name": r["product_name"],
            "product_class": r["product_class"], "posts": int(r["product_mentions"] or 0),
            "names": []})
        p["names"].append(r)
    return [p for p in products.values() if p["posts"] >= CONSOLIDATE_MIN_POSTS]


def _product_types(backend: str) -> dict:
    """product_key -> product_type, from the labels phase 2 wrote (empty before the
    first labelling run, in which case the brand guard has nothing to guard)."""
    rel = ("ust_databricks.ust_staging" if backend == "databricks" else "ust_staging")         + ".stg_mentionlytics__product_profile"
    try:
        return {r["product_key"]: r["product_type"] for r in _query(
            backend, f"select product_key, product_type from {rel}")}
    except Exception:
        return {}


def consolidate_call(client, model: str, clusters: list) -> list:
    """-> list of (cluster_index, [product indexes that are one product])."""
    text = "\n\n".join(
        f"GROUP {g}\n" + "\n".join(f"  {i}. [{p['product_class']}] {p['product_name']}"
                                     for i, p in enumerate(c))
        for g, c in enumerate(clusters))
    resp = client.messages.create(model=model, max_tokens=MAX_TOKENS, system=CONSOLIDATE_INSTRUCTIONS,
                                  messages=[{"role": "user", "content": text}])
    out = []
    for line in "".join(getattr(b, "text", "") for b in resp.content).splitlines():
        parts = [x.strip() for x in line.split("\t")]
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        g = int(parts[0])
        idx = sorted({int(x) for x in re.findall(r"\d+", parts[1])})
        if g < len(clusters) and len(idx) >= 2 and all(i < len(clusters[g]) for i in idx):
            out.append((g, idx))
    return out


def run_consolidation(backend: str, model: str, concurrency: int, dry_run=False, all_groups=False) -> None:
    """INCREMENTAL by default: only look-alike groups holding at least one product whose
    names were ALL first canonicalised after the last checkpoint (i.e. a product new
    since the last run) are asked about, so a weekly run costs a handful of calls instead
    of re-asking every group it has already decided. all_groups=True re-checks
    everything (after a prompt change)."""
    products = read_product_names(backend)
    clusters = consolidation_clusters(products)
    since = "" if all_groups else last_checkpoint(backend)
    if since:
        first_seen = read_first_seen(backend)
        def is_new(p):
            seen = [first_seen.get((n["concept_class"], n["concept_norm"]), "") for n in p["names"]]
            return bool(seen) and min(seen) > since
        clusters = [c for c in clusters if any(is_new(p) for p in c)]
    print(f"checking groups with products new since: {since or 'the beginning'}")
    calls = [clusters[i:i + CONSOLIDATE_PER_CALL] for i in range(0, len(clusters), CONSOLIDATE_PER_CALL)]
    print(f"{len(products):,} products with >= {CONSOLIDATE_MIN_POSTS} posts; "
          f"{len(clusters):,} look-alike groups (~{len(calls)} calls)")
    if dry_run:
        for c in clusters[:15]:
            print("   ", " | ".join(f"{p['product_name']} ({p['posts']})" for p in c))
        return
    if not clusters:
        write_checkpoint(backend, model)
        return
    # BRAND GUARD: a branded product is never merged with an unbranded one, whatever the
    # LLM says. The first run merged "fresh eggs" into "cp fresh eggs" (every generic egg
    # post credited to one brand) and "mydibel frozen shoestring fries" into "shoestring
    # fries" (the brand lost) — exactly the links promo matching depends on.
    labels = _product_types(backend)
    client = get_client(backend)
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        answers = list(pool.map(lambda cl: _safe(consolidate_call, client, model, cl), calls))
    now = datetime.now(timezone.utc).replace(tzinfo=None).isoformat(sep=" ", timespec="seconds")
    records, merged = [], 0
    for chunk, ans in zip(calls, answers):
        for g, idx in ans or []:
            same = sorted((chunk[g][i] for i in idx), key=lambda p: -p["posts"])
            target = same[0]
            branded = labels.get(target["product_key"]) == "branded"
            dupes = [d for d in same[1:] if (labels.get(d["product_key"]) == "branded") == branded]
            for d in same[1:]:
                if d not in dupes:
                    print(f"  (kept apart, branded vs not) {target['product_name']}  /  {d['product_name']}")
            if not dupes:
                continue
            merged += len(dupes)
            print(f"  {target['product_name']}  <-  " + ", ".join(d["product_name"] for d in dupes))
            for d in dupes:
                for n in d["names"]:
                    records.append({"concept_class": n["concept_class"], "concept_norm": n["concept_norm"],
                                    "concept_text": n.get("concept_text"),
                                    "canonical_name": target["product_name"],
                                    "canonical_class": n.get("canonical_class") or target["product_class"],
                                    "canonicalized_at": now,
                                    "model_version": f"{model}/{PROMPT_VERSION}"})
    write(backend, records)
    write_checkpoint(backend, model)   # only after the merges are saved
    print(f"done — {merged:,} duplicate products merged ({len(records):,} spellings re-pointed)")


# ─────────────────────────────────────────────────────────────────────────────
# Phase 2: label every product (type + brand)
# ─────────────────────────────────────────────────────────────────────────────

_PROFILE_LINE = re.compile(r"^\s*(\d+)\.?\s*\t\s*(.*?)\s*\t\s*(branded|shelf|generic)\s*\t\s*(.*?)\s*$",
                           re.IGNORECASE)


def read_products(backend: str) -> list[dict]:
    """Every product in int_social_concept_canon, with a few of its spellings,
    most-posted first."""
    rel = DBX_CANON_REL if backend == "databricks" else DUCKDB_CANON_REL
    rows = _query(backend, f"""
        select product_key, product_name, product_class, concept_norm, name_mentions, product_mentions
        from {rel}
    """)
    products = {}
    for r in sorted(rows, key=lambda x: -int(x["name_mentions"] or 0)):
        p = products.setdefault(r["product_key"], {
            "product_key": r["product_key"], "product_name": r["product_name"],
            "product_class": r["product_class"], "posts": int(r["product_mentions"] or 0),
            "spellings": []})
        if len(p["spellings"]) < 3:
            p["spellings"].append(r["concept_norm"])
    return sorted(products.values(), key=lambda p: -p["posts"])


def read_profiled(backend: str) -> set:
    version = f"%/{PROFILE_VERSION}"
    if backend == "databricks":
        return {r["product_key"] for r in _query(
            backend, f"select product_key from {DBX_PROFILE_TABLE} where model_version like '{version}'")}
    import pandas as pd
    path = Path(LOCAL_PROFILE_PATH)
    if not path.exists():
        return set()
    df = pd.read_parquet(path)
    return set(df[df["model_version"].fillna("").str.endswith(f"/{PROFILE_VERSION}")]["product_key"])


def profile_batch(client, model: str, batch: list) -> list:
    lines = "\n".join(f"{i}. [{p['product_class']}] {p['product_name']} | spellings seen: "
                      + ", ".join(p["spellings"]) for i, p in enumerate(batch))
    parsed = {}
    for _ in range(2):          # one retry for a reply that came back short or garbled
        resp = client.messages.create(model=model, max_tokens=MAX_TOKENS, system=PROFILE_INSTRUCTIONS,
                                      messages=[{"role": "user", "content": lines}])
        parsed = {}
        for line in "".join(getattr(b, "text", "") for b in resp.content).splitlines():
            m = _PROFILE_LINE.match(line)
            if (m and int(m.group(1)) < len(batch)
                    and echo_matches(m.group(2), batch[int(m.group(1))]["product_name"])):
                brand = m.group(4).strip().strip('"')
                parsed[int(m.group(1))] = (m.group(3).lower(), None if brand in ("", "-") else brand)
        if len(parsed) >= len(batch) * 0.9:
            break
    now = datetime.now(timezone.utc).replace(tzinfo=None).isoformat(sep=" ", timespec="seconds")
    return [{"product_key": p["product_key"], "product_name": p["product_name"],
             "product_type": parsed[i][0], "brand": parsed[i][1], "profiled_at": now,
             "model_version": f"{model}/{PROFILE_VERSION}"}
            for i, p in enumerate(batch) if i in parsed]


def run_profiles(backend: str, model: str, concurrency: int, limit=None, dry_run=False) -> None:
    products = read_products(backend)
    done = read_profiled(backend)
    todo = [p for p in products if p["product_key"] not in done]
    if limit:
        todo = todo[:limit]
    print(f"{len(products):,} products; {len(done):,} already labelled at {PROFILE_VERSION}; "
          f"{len(todo):,} to do (~{-(-len(todo) // PROFILE_BATCH_SIZE)} calls)")
    if dry_run or not todo:
        return
    batches = [todo[i:i + PROFILE_BATCH_SIZE] for i in range(0, len(todo), PROFILE_BATCH_SIZE)]
    t0, written = time.time(), 0
    for w in range(0, len(batches), WAVE_BATCHES):
        wave = batches[w:w + WAVE_BATCHES]
        client = get_client(backend)        # fresh token per wave (they last ~1 hour)
        with ThreadPoolExecutor(max_workers=concurrency) as pool:
            results = list(pool.map(lambda b: _safe(profile_batch, client, model, b), wave))
        records = [r for res in results for r in res]
        write(backend, records, DBX_PROFILE_TABLE, LOCAL_PROFILE_PATH, PROFILE_COLUMNS)
        written += len(records)
        print(f"  wave {w // WAVE_BATCHES + 1}/{-(-len(batches) // WAVE_BATCHES)}: "
              f"{len(records)} products ({written:,} total, {time.time() - t0:.0f}s)")
    print(f"done — {written:,} of {len(todo):,} products labelled; the rest retry next run")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--backend", choices=["local", "databricks"], default="local")
    ap.add_argument("--init", action="store_true", help="create the empty landing tables and exit")
    ap.add_argument("--consolidate", action="store_true",
                    help="phase 1b: merge near-duplicate products (after dbt rebuilds int_social_concept_canon)")
    ap.add_argument("--all", dest="all_groups", action="store_true",
                    help="with --consolidate: re-check every look-alike group, not only products new since the last run")
    ap.add_argument("--profile-products", action="store_true",
                    help="phase 2: label every product not yet labelled (type + brand)")
    ap.add_argument("--dry-run", action="store_true", help="count names to canonicalise; no LLM")
    ap.add_argument("--limit", type=int, help="canonicalise at most this many names (smoke test)")
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--concurrency", type=int, default=CONCURRENCY)
    args = ap.parse_args(argv)

    init_landing(args.backend)
    if args.init:
        return
    if args.consolidate:
        run_consolidation(args.backend, args.model, args.concurrency, args.dry_run, args.all_groups)
        return
    if args.profile_products:
        run_profiles(args.backend, args.model, args.concurrency, args.limit, args.dry_run)
        return
    names = read_names(args.backend)
    done = read_done(args.backend)
    done_keys = {(r["concept_class"], r["concept_norm"]) for r in done}
    posts_by_name = {(r["concept_class"], r["concept_norm"]): int(r["posts"]) for r in names}
    redo = read_misaligned(args.backend, posts_by_name)
    todo = [r for r in names if (r["concept_class"], r["concept_norm"]) not in done_keys
            or (r["concept_class"], r["concept_norm"]) in redo]
    if args.limit:
        todo = todo[: args.limit]
    print(f"{len(names):,} names in all history; {len(done_keys):,} already canonicalised at "
          f"{PROMPT_VERSION}; {len(todo):,} to do (~{-(-len(todo) // BATCH_SIZE)} calls), "
          f"{len(redo):,} of them re-asked because their batch was answered one line off")
    if args.dry_run or not todo:
        return

    batches = [todo[i:i + BATCH_SIZE] for i in range(0, len(todo), BATCH_SIZE)]
    t0, written = time.time(), 0
    for w in range(0, len(batches), WAVE_BATCHES):
        wave = batches[w:w + WAVE_BATCHES]
        # a fresh token every wave: serving tokens last ~1 hour, and the 2026-10-05
        # backfill lost its last 7,500 names to "Invalid Token" on a single client
        client = get_client(args.backend)
        hints = top_hints(done, posts_by_name)
        with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
            results = list(pool.map(lambda b: _safe(canonicalize_batch, client, args.model, b, hints), wave))
        records = [r for res in results for r in res]
        write(args.backend, records)          # saved per wave: an interrupted run loses one wave at most
        done += records
        written += len(records)
        print(f"  wave {w // WAVE_BATCHES + 1}/{-(-len(batches) // WAVE_BATCHES)}: "
              f"{len(records)} names ({written:,} total, {time.time() - t0:.0f}s)")
    print(f"done — {written:,} of {len(todo):,} names canonicalised; the rest retry next run")


def _safe(fn, *a):
    try:
        return fn(*a)
    except Exception as e:                     # one failed batch never sinks the wave
        print(f"    ! batch failed: {str(e)[:150]}")
        return []


if __name__ == "__main__":
    main()
