"""Resolve trending social CONCEPTS to WMS SKUs (step ③, OUT-OF-BAND from dbt).

Sibling of scripts/enrich_mentions.py — SAME LLM setup (Databricks-hosted Claude
via the workspace serving endpoint, ambient auth on the databricks backend). dbt
stays deterministic and never calls the LLM; this writes a table dbt then reads.
GATED: only the top-N ranked concepts are resolved, so the long tail costs nothing.

WHY IT READS MENTION SNIPPETS (learned 2026-07-30): a bare token like "pork" or
"7-eleven" has no meaning on its own — "pork" might be หมูกระจก (crispy pork jerky)
or หมูกระทะ (Thai BBQ), never "pork skin". So for each trending concept the model
is given a few REAL mention snippets (title/content + the AI arrays) and must:
  1. CANONICALISE   — one display name, merging cross-language/spelling variants
                      (som tam / ส้มตำ -> "Som Tam (green papaya salad)").
  2. CLASSIFY       — carried / substitute / basket / none (see INSTRUCTIONS).
  3. MATCH SEMANTICALLY against the real catalog, reading the context — NOT by
     string overlap.

Flow position (weekly social job):
    parse_mentions  ->  social.mentions
    enrich_mentions ->  social.mention_enrichment
    dbt build --select +int_social_concept_trends          (deterministic ranking)
 >> resolve_trending_concepts (THIS) ->  social.concept_resolution
    dbt build --select tag:social                          (mart joins the resolution)

  --backend local       reads the local duckdb build, writes
                        data/mock/mentionlytics/concept_resolution.parquet
  --backend databricks  reads ust_databricks.ust_intermediate.*, writes
                        ust_databricks.social.concept_resolution (Delta)

NOTE: the serving endpoint needs the model-serving scope — available to the
Databricks job's run-as identity, NOT to a plain SQL PAT. Run the real resolution
as the databricks job. Smoke-test prompts locally with --dry-run.

    python scripts/resolve_trending_concepts.py --backend local --dry-run
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

import yaml

# ─────────────────────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────────────────────

def _find_dbt_project_path():
    """Locate dbt_project.yml. Prefers a path relative to this script file,
    but __file__ is NOT always defined — Databricks Python-script tasks run
    this via exec(compile(...)) in a notebook-style wrapper, which never sets
    __file__ in the exec'd globals, unlike a normal `python script.py` run or
    module import. Falls back to searching upward from the current working
    directory so the job doesn't crash on that difference."""
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


DBT_PROJECT_PATH = _find_dbt_project_path()


def _dbt_var(name, default):
    """Read a var from dbt_project.yml's vars: block — the SAME block
    mart_social_trending_items.sql reads via {{ var(...) }} — so this script
    and the mart share one source of truth instead of two independent
    hardcoded numbers that can silently drift apart. Falls back to `default`
    if the file is missing/malformed (e.g. the script ever runs standalone,
    without the rest of the repo checked out alongside it)."""
    try:
        data = yaml.safe_load(DBT_PROJECT_PATH.read_text(encoding="utf-8"))
        return data["vars"][name]
    except Exception:
        return default


MODEL = "databricks-claude-haiku-4-5"   # same endpoint as enrich_mentions
PROMPT_VERSION = "v4"                    # v4 = carried-first (inventory match wins over baskets)
_CURRENT_VERSION = f"{MODEL}/{PROMPT_VERSION}"  # stamp on each row; drives version-aware re-resolve
MAX_TOKENS = 700
CONCURRENCY = 4
MAX_RETRIES = 8
MAX_ATTEMPTS = 2
BATCH_SIZE = 100
# gate: resolve concepts at trend_rank <= this. Reads dbt_project.yml's
# social_trend_top_n — the same var the mart uses — instead of a second,
# independent hardcoded "20" that could quietly drift from it.
TOP_N = _dbt_var("social_trend_top_n", 20)
SNIPPETS_PER_CONCEPT = 6               # representative mentions shown to the model
SNIPPET_CHARS = 220

LOCAL_DUCKDB_PATH = "dev.duckdb"
LOCAL_RESOLUTION_PATH = "data/mock/mentionlytics/concept_resolution.parquet"

DBX_TRENDS_TABLE = "ust_databricks.ust_intermediate.int_social_concept_trends"
DBX_ITEMS_TABLE = "ust_databricks.ust_intermediate.int_jdawms_items"
DBX_FCT_TABLE = "ust_databricks.ust_facts.fct_social_mentions"
DBX_RESOLUTION_TABLE = "ust_databricks.social.concept_resolution"
DUCKDB_TRENDS_REL = "ust_intermediate.int_social_concept_trends"
DUCKDB_ITEMS_REL = "ust_intermediate.int_jdawms_items"
DUCKDB_FCT_REL = "ust_facts.fct_social_mentions"

INSTRUCTIONS = """You map a TRENDING FOOD CONCEPT from Thai/Vietnamese social \
listening to products in a food distributor's warehouse catalog. You are given \
the catalog (part numbers, names, families) as reference, then ONE concept at a \
time together with a few REAL social-mention snippets that mention it.

READ THE SNIPPETS to understand what people are actually talking about before you \
decide — a word alone is ambiguous ("pork" may be crispy pork jerky หมูกระจก or a \
BBQ, never "pork skin").

Then return ONE JSON object — no markdown, no prose — exactly:
{
  "canonical_label": string,       // one clean display name; merge language/spelling
                                   //   variants (som tam / ส้มตำ -> "Som Tam (green papaya salad)")
  "concept_type": string,          // "dish" | "category" | "ingredient" | "product" | "brand"
  "result_type": string,           // see below
  "matched_prtnum": string|null,   // only for "carried"
  "recommended_prtnums": [string], // for "substitute"/"basket"; [] otherwise
  "recommended_item_names": [string], // display names, SAME ORDER as recommended_prtnums
  "match_confidence": number       // 0.0–1.0
}

CHECK "carried" FIRST — inventory match wins. If the catalog contains the item \
itself as a ready-to-sell product (a banh mi product, a matcha product, a \
spring-roll product), return "carried" with that SKU, EVEN FOR A DISH. Only fall \
to substitute / basket / none when we do NOT stock the item directly. Order of \
preference: carried > substitute/basket > none. A direct product a rep can sell \
beats a basket of ingredients every time.

result_type decides what we show marketing:
  - "carried"   : the concept IS a product/ingredient we stock -> set matched_prtnum.
  - "substitute": a product we do NOT stock but we carry a GENUINELY CLOSE
                  alternative — the SAME KIND of food a shopper would accept
                  instead -> recommended_prtnums = the nearest 1-3 items we carry.
  - "basket"    : a DISH or high-level CATEGORY (not one SKU), e.g. "som tam",
                  "pad thai" -> recommended_prtnums = ONLY the CORE, DEFINING
                  ingredients of THIS specific dish that we carry — the items that
                  make it that dish, from the SAME cuisine. 2-5 items, not a padded
                  list. If you can't confidently name core ingredients we stock,
                  return FEWER or an empty list — an empty basket beats a wrong one.
  - "none"      : nothing in the catalog is a real fit -> empty arrays.

PREFER "none" OR AN EMPTY BASKET OVER A WEAK MATCH. If no catalog item is genuinely \
the same kind of food, return "none" — do NOT stretch. Two hard rules: a substitute \
must be something a shopper would actually accept in place of the trending item; a \
basket item must be a defining ingredient of THAT dish. NEVER include generic, \
tangential, or different-cuisine items (do NOT put green jackfruit or Korean beef \
bulgogi under a Thai/Vietnamese dish just because they are food). Set \
match_confidence to reflect precision — high ONLY when the items clearly define the \
dish; lower it when the basket is loose. A low value is fine and far better than a \
confident-looking wrong match.

Rules: every prtnum you output MUST exist in the catalog exactly; names line up \
1:1 with prtnums. Judge on MEANING across Thai / Vietnamese / English, never on \
keyword overlap."""

_REQUIRED_KEYS = {
    "canonical_label", "concept_type", "result_type", "matched_prtnum",
    "recommended_prtnums", "recommended_item_names", "match_confidence",
}
_VALID_RESULT = {"carried", "substitute", "basket", "none"}


# ─────────────────────────────────────────────────────────────────────────────
# Serving-endpoint client — identical pattern to enrich_mentions.py
# ─────────────────────────────────────────────────────────────────────────────

def _resolve_host_token(backend):
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
            "for local runs, or run on Databricks compute (ambient auth). The token "
            "must have the model-serving scope."
        )
    return host.replace("https://", "").rstrip("/"), token


def get_client(backend):
    import anthropic
    host, token = _resolve_host_token(backend)
    return anthropic.Anthropic(
        api_key="unused",
        base_url=f"https://{host}/serving-endpoints/anthropic",
        default_headers={"Authorization": f"Bearer {token}"},
        max_retries=MAX_RETRIES,
    )


# ─────────────────────────────────────────────────────────────────────────────
# Backend I/O
# ─────────────────────────────────────────────────────────────────────────────

def _top_concepts_sql(trends_rel, top_n):
    """Distinct concepts anywhere in the top-N of any period/grain."""
    return f"""
        select concept_norm, any_value(concept_source) as concept_source,
               sum(mention_count) as mention_count
        from {trends_rel}
        where trend_rank <= {top_n}
        group by concept_norm
    """


def _snippet_source_sql(fct_rel):
    """Mentions carrying the specific-product arrays + text, for snippet buckets."""
    return f"""
        select mention_id,
               coalesce(title, substr(content, 1, {SNIPPET_CHARS})) as snippet,
               mentioned_dishes, ingredients, brands,
               coalesce(total_engagement, 0) as engagement
        from {fct_rel}
        where mentioned_dishes is not null or brands is not null
    """


def read_all(backend, top_n, duckdb_path):
    """Return (concepts, snippets_by_concept, catalog, already_resolved_count)."""
    if backend == "databricks":
        spark = _get_spark()
        concepts = [r.asDict() for r in
                    spark.sql(_top_concepts_sql(DBX_TRENDS_TABLE, top_n)).collect()]
        mentions = [r.asDict() for r in
                    spark.sql(_snippet_source_sql(DBX_FCT_TABLE)).collect()]
        catalog = [r.asDict() for r in spark.table(DBX_ITEMS_TABLE)
                   .select("prtnum", "item_name", "item_family").collect()]
        try:
            # VERSION-AWARE: only concepts resolved at the CURRENT model+prompt
            # version count as done. Bumping PROMPT_VERSION drops every stale row
            # out of this set, so the next run re-resolves it automatically — no
            # manual truncate needed, still incremental (only stale + new).
            resolved = {r.concept_norm for r in spark.sql(
                f"select concept_norm from {DBX_RESOLUTION_TABLE} "
                f"where model_version = '{_CURRENT_VERSION}'").collect()}
        except Exception:
            resolved = set()
    else:
        import duckdb
        con = duckdb.connect(duckdb_path, read_only=True)
        concepts = con.sql(_top_concepts_sql(DUCKDB_TRENDS_REL, top_n)).df().to_dict("records")
        mentions = con.sql(_snippet_source_sql(DUCKDB_FCT_REL)).df().to_dict("records")
        catalog = con.sql(
            f"select prtnum, item_name, item_family from {DUCKDB_ITEMS_REL}"
        ).df().to_dict("records")
        con.close()
        try:
            import duckdb as _d
            resolved = set(_d.connect().sql(
                f"select concept_norm from read_parquet('{LOCAL_RESOLUTION_PATH}') "
                f"where model_version = '{_CURRENT_VERSION}'"
            ).df()["concept_norm"].tolist())
        except Exception:
            resolved = set()

    wanted = {c["concept_norm"] for c in concepts}
    snippets = bucket_snippets(mentions, wanted)
    new = [c for c in concepts if c["concept_norm"] not in resolved]
    return new, snippets, catalog, len(resolved)


# Copied character-for-character from macros/fold_concept.sql's translate()
# call, so the two can't silently drift apart again. A general Unicode
# NFKD/combining-mark strip (the previous approach) also strips THAI tone
# marks and vowel signs — Thai combining characters aren't in this table, so
# they must pass through byte-for-byte unchanged, exactly like the SQL side.
_FOLD_FROM = "àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ"
_FOLD_TO = "aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd"
_FOLD_TABLE = str.maketrans(_FOLD_FROM, _FOLD_TO)


def _fold(s):
    """Match macros/fold_concept.sql EXACTLY: lower+trim, translate() over the
    same 67 Vietnamese-diacritic characters (+ đ->d), collapse spaces. Thai (and
    anything else not in the table) passes through unchanged, same as the SQL."""
    s = str(s).strip().lower().translate(_FOLD_TABLE)
    return re.sub(" +", " ", s)


def _norm_list(v):
    if v is None:
        return []
    try:
        return [_fold(x) for x in list(v) if x is not None and str(x).strip()]
    except TypeError:
        return []


def bucket_snippets(mentions, wanted):
    """{concept_norm: [ (engagement, snippet_dict), ... ]} keeping the loudest few."""
    buckets = defaultdict(list)
    for m in mentions:
        keys = set(_norm_list(m.get("mentioned_dishes")) + _norm_list(m.get("brands")))
        hit = keys & wanted
        if not hit:
            continue
        snip = {
            "text": (m.get("snippet") or "").replace("\n", " ")[:SNIPPET_CHARS],
            "dishes": _norm_list(m.get("mentioned_dishes")),
            "ingredients": _norm_list(m.get("ingredients")),
        }
        eng = m.get("engagement") or 0
        for cn in hit:
            buckets[cn].append((eng, snip))
    for cn in buckets:
        buckets[cn] = [s for _, s in sorted(buckets[cn], key=lambda t: -t[0])][:SNIPPETS_PER_CONCEPT]
    return buckets


def write_resolution(backend, records):
    if not records:
        return
    if backend == "databricks":
        spark = _get_spark()
        df = spark.createDataFrame(records, schema=_dbx_resolution_schema())
        (df.write.format("delta").mode("append")
           .option("mergeSchema", "true").saveAsTable(DBX_RESOLUTION_TABLE))
    else:
        import pandas as pd
        new_df = pd.DataFrame(records)
        if os.path.exists(LOCAL_RESOLUTION_PATH):
            new_df = pd.concat([pd.read_parquet(LOCAL_RESOLUTION_PATH), new_df],
                               ignore_index=True)
        os.makedirs(os.path.dirname(LOCAL_RESOLUTION_PATH), exist_ok=True)
        new_df.to_parquet(LOCAL_RESOLUTION_PATH, index=False)


def _dbx_resolution_schema():
    from pyspark.sql.types import (
        StructType, StructField, StringType, DoubleType, ArrayType, TimestampType,
    )
    arr = ArrayType(StringType())
    return StructType([
        StructField("concept_norm", StringType()),
        StructField("canonical_label", StringType()),
        StructField("concept_type", StringType()),
        StructField("result_type", StringType()),
        StructField("matched_prtnum", StringType()),
        StructField("recommended_prtnums", arr),
        StructField("recommended_item_names", arr),
        StructField("match_confidence", DoubleType()),
        StructField("resolved_at", TimestampType()),
        StructField("model_version", StringType()),
    ])


def _get_spark():
    try:
        return spark  # noqa: F821 — Databricks global
    except NameError:
        from pyspark.sql import SparkSession
        return SparkSession.builder.getOrCreate()


# ─────────────────────────────────────────────────────────────────────────────
# LLM core
# ─────────────────────────────────────────────────────────────────────────────

def build_catalog_block(catalog):
    """Catalog reference, sent once as a cached system block.

    TODO(scale): 5.7k rows is fine as one cached block. If it grows or matches get
    noisy, shortlist per concept (family/lexical prefilter) and pass only candidates.
    """
    lines = [f"{c['prtnum']}\t{c.get('item_name')}\t{c.get('item_family')}"
             for c in catalog]
    return "CATALOG (prtnum<TAB>item_name<TAB>item_family):\n" + "\n".join(lines)


def build_user_prompt(concept, snippets):
    lines = [
        f"Concept (raw): {concept['concept_norm']}",
        f"Seen as: {concept.get('concept_source')}   Mentions: {concept.get('mention_count')}",
        "",
        "Representative mentions:",
    ]
    if not snippets:
        lines.append("  (no snippets found)")
    for s in snippets:
        lines.append(f"  - {s['text']}")
        extra = []
        if s["dishes"]:
            extra.append("dishes=" + ", ".join(s["dishes"][:6]))
        if s["ingredients"]:
            extra.append("ingredients=" + ", ".join(s["ingredients"][:8]))
        if extra:
            lines.append("      (" + "; ".join(extra) + ")")
    return "\n".join(lines)


def extract_json(text):
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\n?", "", text)
        text = re.sub(r"\n?```$", "", text).strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", text, re.DOTALL)
        return json.loads(m.group(0)) if m else None


def resolve_one(client, catalog_block, concept, snippets):
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            resp = client.messages.create(
                model=MODEL,
                max_tokens=MAX_TOKENS,
                system=[
                    {"type": "text", "text": INSTRUCTIONS},
                    {"type": "text", "text": catalog_block,
                     "cache_control": {"type": "ephemeral"}},
                ],
                messages=[{"role": "user",
                           "content": build_user_prompt(concept, snippets)}],
            )
            text = next((b.text for b in resp.content if b.type == "text"), "")
            data = extract_json(text)
            if (data and _REQUIRED_KEYS.issubset(data)
                    and data.get("result_type") in _VALID_RESULT):
                return data
        except Exception as e:
            if attempt == MAX_ATTEMPTS:
                print(f"  WARN concept {concept['concept_norm']!r}: {e}", file=sys.stderr)
    return None


def resolve_batch(client, catalog_block, concepts, snippets_by_concept, concurrency):
    out = {}
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = {
            pool.submit(resolve_one, client, catalog_block, c,
                        snippets_by_concept.get(c["concept_norm"], [])): c
            for c in concepts
        }
        for fut in futures:
            c = futures[fut]
            data = fut.result()
            if data is not None:
                out[c["concept_norm"]] = data
    return out


def to_records(by_concept, resolved_at, catalog_by_prtnum):
    """Build enrichment rows, VALIDATING every prtnum the LLM returned against the
    real catalog: drop any recommended/matched prtnum that isn't a real SKU, and
    take the item name from the catalog (never the LLM's self-reported name — it
    can drift from the prtnum). This guarantees downstream only ever sees real
    SKUs with their true names."""
    model_version = _CURRENT_VERSION
    records = []
    for concept_norm, a in by_concept.items():
        # keep only recommended prtnums that exist; name comes from the catalog
        prtnums, names = [], []
        for p in (a.get("recommended_prtnums") or []):
            p = str(p)
            if p in catalog_by_prtnum:
                prtnums.append(p)
                names.append(str(catalog_by_prtnum[p]))
        matched = (str(a["matched_prtnum"]) if a.get("matched_prtnum") else None)
        if matched is not None and matched not in catalog_by_prtnum:
            matched = None  # LLM hallucinated a SKU that doesn't exist
        records.append({
            "concept_norm": str(concept_norm),
            "canonical_label": str(a.get("canonical_label") or concept_norm),
            "concept_type": str(a["concept_type"]),
            "result_type": str(a["result_type"]),
            "matched_prtnum": matched,
            "recommended_prtnums": prtnums,
            "recommended_item_names": names,
            "match_confidence": float(a["match_confidence"]),
            "resolved_at": resolved_at,
            "model_version": model_version,
        })
    return records


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def main(backend="local", limit=None, top_n=TOP_N, dry_run=False,
         concurrency=CONCURRENCY, duckdb_path=LOCAL_DUCKDB_PATH):
    concepts, snippets, catalog, n_resolved = read_all(backend, top_n, duckdb_path)
    if limit:
        concepts = concepts[:limit]
    print(f"{n_resolved} already resolved; {len(concepts)} new top-{top_n} "
          f"concepts to resolve; catalog has {len(catalog)} items")
    if not concepts:
        print("nothing to do.")
        return

    catalog_block = build_catalog_block(catalog)
    catalog_by_prtnum = {str(c["prtnum"]): c.get("item_name") for c in catalog}

    if dry_run:
        print(f"[dry-run] would resolve {len(concepts)} concepts with {MODEL}.")
        print(f"catalog block: {len(catalog_block)} chars. First prompt:\n")
        c0 = concepts[0]
        print(build_user_prompt(c0, snippets.get(c0["concept_norm"], [])))
        return

    client = get_client(backend)
    total = len(concepts)
    written = 0
    for start in range(0, total, BATCH_SIZE):
        chunk = concepts[start:start + BATCH_SIZE]
        res = resolve_batch(client, catalog_block, chunk, snippets, concurrency)
        write_resolution(backend, to_records(res, datetime.now(timezone.utc),
                                             catalog_by_prtnum))
        written += len(res)
        print(f"  batch {start // BATCH_SIZE + 1}: wrote {len(res)}/{len(chunk)} "
              f"(cumulative {written}/{total})")

    failed = total - written
    print(f"DONE. wrote {written} resolution rows"
          + (f"; {failed} failed — re-run to backfill (incremental)" if failed else ""))


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--backend", choices=["local", "databricks"], default="local")
    p.add_argument("--top-n", type=int, default=TOP_N,
                   help=f"resolve concepts at trend_rank <= this "
                        f"(default {TOP_N}, from dbt_project.yml's social_trend_top_n)")
    p.add_argument("--limit", type=int, help="resolve at most N new concepts (smoke test)")
    p.add_argument("--concurrency", type=int, default=CONCURRENCY)
    p.add_argument("--duckdb", default=LOCAL_DUCKDB_PATH,
                   help=f"local duckdb build path (default {LOCAL_DUCKDB_PATH})")
    p.add_argument("--dry-run", action="store_true", help="build prompts only; no API call")
    args = p.parse_args()
    try:
        sys.stdout.reconfigure(encoding="utf-8")  # concepts carry Thai/Vietnamese text
    except Exception:
        pass
    main(backend=args.backend, limit=args.limit, top_n=args.top_n,
         dry_run=args.dry_run, concurrency=args.concurrency, duckdb_path=args.duckdb)
