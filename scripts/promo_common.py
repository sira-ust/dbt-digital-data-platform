"""Shared helpers for the monthly promo x social match pipeline.

Imported by load_promo_list.py, draft_promo_terms.py, match_promo_social.py,
youtube_search.py and export_promo_social_match.py. Pure helpers (text
normalisation, the term matcher, JSON parsing) import without pyspark or the
network, so tests/python can exercise them directly.

ONE MATCHER, THREE SOURCES. The keyword rule that decides Exact / Close is
written once here and used for Mentionlytics posts and YouTube videos alike,
and the TikTok prompt states the same rule in words. The spec's "Exact means
exact" test only means something if every source is held to the same rule.

How a term matches (see compile_term):
  * all text is NFKC-normalised and casefolded first. Mentionlytics stores some
    Vietnamese in decomposed form (78 of 49,203 posts in the 2026-09-21 export),
    which would otherwise never match a precomposed term; NFKC also unifies Thai
    sara am (ำ vs ํา) and full-width Latin;
  * Thai / Japanese / Chinese / Korean terms match as plain substrings, because
    those scripts do not separate words with spaces;
  * every other term matches on WHOLE WORDS only, so "cozy" does not fire
    inside "cozytea" and "sting" does not fire inside "stingray";
  * a MULTI-WORD term written without Vietnamese accents ("chuon chuon",
    "tra vai") also matches the accented spelling, via a copy of the text with
    accents folded away. Single words never fold: Vietnamese is full of short
    words that differ only by accent, and "cam" (orange) must not find "cảm ơn"
    (thank you), nor "tắc" (kumquat) find "tác". A term written WITH accents
    matches only that exact spelling.

Every hit is returned as the exact token found in match_text(), so a stored
hit can be re-checked later with a plain substring test (that is what
tests/assert_promo_exact_has_terms.sql does).
"""

from __future__ import annotations

import json
import os
import re
import unicodedata
from pathlib import Path

# ─────────────────────────────────────────────────────────────────────────────
# Project / config
# ─────────────────────────────────────────────────────────────────────────────

DATABRICKS_HOST = os.environ.get(
    "DATABRICKS_HOST", "adb-7405618436278207.7.azuredatabricks.net"
).replace("https://", "").rstrip("/")
CATALOG = "ust_databricks"
SOCIAL_SCHEMA = f"{CATALOG}.social"
STAGING_SCHEMA = f"{CATALOG}.ust_staging"
INTERMEDIATE_SCHEMA = f"{CATALOG}.ust_intermediate"
REPORTING_SCHEMA = f"{CATALOG}.ust_reporting"
LOCAL_DUCKDB_PATH = "dev.duckdb"


def find_project_root() -> Path:
    """The dbt project folder. __file__ is not always defined (Databricks
    Python-script tasks exec() the file), so fall back to searching upward from
    the working directory — same approach as enrich_mentions.py."""
    candidates = []
    try:
        candidates.append(Path(__file__).resolve().parents[1])
    except NameError:
        pass
    cur = Path.cwd()
    for _ in range(6):
        candidates.append(cur)
        if cur.parent == cur:
            break
        cur = cur.parent
    for c in candidates:
        if (c / "dbt_project.yml").exists():
            return c
    return candidates[0] if candidates else Path.cwd()


def dbt_var(name, default=None):
    """A var from dbt_project.yml, so scripts and models share one number."""
    try:
        import yaml
        data = yaml.safe_load((find_project_root() / "dbt_project.yml").read_text(encoding="utf-8"))
        return data["vars"].get(name, default)
    except Exception:
        return default


def local_data_root(override=None) -> Path:
    """data/mock by default; data/real when testing on the real snapshot. The
    same folder the dbt sources read (var local_data_root)."""
    root = override or os.environ.get("PROMO_LOCAL_DATA_ROOT") or dbt_var("local_data_root", "data/mock")
    p = Path(root)
    return p if p.is_absolute() else find_project_root() / p


# ─────────────────────────────────────────────────────────────────────────────
# Text normalisation + the term matcher
# ─────────────────────────────────────────────────────────────────────────────

# scripts without spaces between words: match as substrings, not whole words
_NO_SPACE_SCRIPT = re.compile(r"[฀-๿぀-ヿ㐀-鿿가-힯]")
_LATIN_COMBINING = re.compile(r"[̀-ͯ]")


def norm(text) -> str:
    """NFKC + casefold + collapsed whitespace. Thai and Vietnamese marks survive.
    Thai typists put nikhahit and a tone mark in either order (นํ้า / น้ํา after
    NFKC); the tone-first order is forced so both spellings compare equal."""
    s = unicodedata.normalize("NFKC", str(text or "")).casefold()
    s = re.sub("\u0e4d([\u0e48-\u0e4b])", "\\1\u0e4d", s)
    return re.sub(r"\s+", " ", s).strip()


def fold(text) -> str:
    """norm() with Latin diacritics removed (trà -> tra, đ -> d). Only the Latin
    combining block is stripped, so Thai vowel and tone marks are untouched."""
    s = unicodedata.normalize("NFD", norm(text))
    s = _LATIN_COMBINING.sub("", s).replace("đ", "d")
    return unicodedata.normalize("NFC", s)


def match_text(*parts) -> str:
    """The searchable form of a post: the normalised text, a newline, then its
    accent-folded copy (norm() never leaves a newline, so the split is safe).
    Every hit ItemTerms.classify() returns is a substring of this string."""
    joined = " ".join(str(p) for p in parts if p)
    return f"{norm(joined)}\n{fold(joined)}"


def split_terms(value) -> list[str]:
    """'a | b|c' -> ['a', 'b', 'c']. Terms are pipe-separated in the seed."""
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        items = value
    else:
        items = str(value).split("|")
    out, seen = [], set()
    for t in items:
        t = str(t).strip()
        if t and t.casefold() not in seen and t.lower() not in ("nan", "none"):
            seen.add(t.casefold())
            out.append(t)
    return out


def compile_term(term):
    """(token, regex, scope) for one term. token is stored as the hit; scope says
    which half of match_text() the regex may search: 'norm' (the text as
    written) or 'both' (also the accent-folded copy). See the module docstring."""
    t = norm(term)
    if not t:
        return None
    if _NO_SPACE_SCRIPT.search(t):
        return t, re.compile(re.escape(t)), "norm"
    whole_word = lambda s: re.compile(rf"(?<!\w){re.escape(s)}(?!\w)")
    if fold(t) == t and " " in t:
        return t, whole_word(t), "both"
    return t, whole_word(t), "norm"


class ItemTerms:
    """The compiled search terms for one promo item."""

    def __init__(self, brand_terms, product_terms, flavor_terms=None, negative_terms=None):
        self.brand = [c for c in map(compile_term, split_terms(brand_terms)) if c]
        self.product = [c for c in map(compile_term, split_terms(product_terms)) if c]
        self.flavor = [c for c in map(compile_term, split_terms(flavor_terms)) if c]
        self.negative = [c for c in map(compile_term, split_terms(negative_terms)) if c]

    @property
    def requires_flavor(self) -> bool:
        return bool(self.flavor)

    @staticmethod
    def _first(compiled, text):
        normed, _, folded = text.partition("\n")
        for token, rx, scope in compiled:
            if rx.search(normed) or (scope == "both" and rx.search(folded)):
                return token
        return None

    def classify(self, text_for_match: str) -> dict:
        """Keyword evidence for one post. keyword_level is
             'exact'  brand + product + flavor (flavor only when the item has one)
             'close'  brand + product, or brand + flavor
             None     not a candidate (no brand, brand alone, or a negative term)
        The AI judge can only confirm or LOWER this; an Exact row always carries
        a brand, product and (if required) flavor hit."""
        brand = self._first(self.brand, text_for_match)
        product = self._first(self.product, text_for_match)
        flavor = self._first(self.flavor, text_for_match)
        negative = self._first(self.negative, text_for_match)
        level = None
        if brand and not negative:
            if product and (flavor or not self.requires_flavor):
                level = "exact"
            elif product or flavor:
                level = "close"
        return {"brand_hit": brand, "product_hit": product, "flavor_hit": flavor,
                "negative_hit": negative, "keyword_level": level}


def final_status(keyword_level, verdict):
    """Combine keyword evidence with the judge. The judge may lower a level or
    reject; it may never raise Close to Exact (then the terms are missing)."""
    v = (verdict or "").lower()
    if v not in ("exact", "close"):
        return None
    if v == "exact" and keyword_level == "exact":
        return "Exact"
    return "Close"


# ─────────────────────────────────────────────────────────────────────────────
# LLM (Databricks-hosted Claude)
# ─────────────────────────────────────────────────────────────────────────────

def _bearer_token(backend: str) -> str:
    """A token allowed to call model serving.
    databricks backend: the job's run-as identity (ambient, no secret).
    local: DATABRICKS_SERVING_TOKEN if set, otherwise a browser sign-in (cached
    after the first time). The everyday DATABRICKS_TOKEN PAT is deliberately NOT
    used: it is scoped to SQL and is refused by model serving."""
    from databricks.sdk.core import Config
    if backend == "databricks":
        return Config().authenticate()["Authorization"].split(" ", 1)[1]
    if os.environ.get("DATABRICKS_SERVING_TOKEN"):
        return os.environ["DATABRICKS_SERVING_TOKEN"]
    saved = os.environ.pop("DATABRICKS_TOKEN", None)
    try:
        cfg = Config(host=f"https://{DATABRICKS_HOST}", auth_type="external-browser")
        return cfg.authenticate()["Authorization"].split(" ", 1)[1]
    finally:
        if saved is not None:
            os.environ["DATABRICKS_TOKEN"] = saved


def get_llm_client(backend: str, max_retries: int = 8):
    import anthropic
    return anthropic.Anthropic(
        api_key="unused",
        base_url=f"https://{DATABRICKS_HOST}/serving-endpoints/anthropic",
        default_headers={"Authorization": f"Bearer {_bearer_token(backend)}"},
        max_retries=max_retries,
    )


def extract_json(text):
    """Parse the model's reply into a dict, tolerating stray fences/prose."""
    text = (text or "").strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\n?", "", text)
        text = re.sub(r"\n?```$", "", text).strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", text, re.DOTALL)
        if not m:
            return None
        try:
            return json.loads(m.group(0))
        except json.JSONDecodeError:
            return None


JUDGE_PROMPT_VERSION = "v4"

JUDGE_INSTRUCTIONS = """You check whether a social media post or video is about one specific grocery product that a distributor is promoting.

Give one verdict:
- "exact": the text names this brand AND this product AND, when the item has a flavor/variant, that flavor/variant. A shopper could tell it is this item.
- "close": the post is specifically about this brand's product of this kind, but it does not say which flavor/variant; OR it is this very product in a different format or pack (e.g. the instant-powder version of the same tea, a seasoned version of the same rice paper).
- "reject": everything else, including:
  * the post names a DIFFERENT flavor, variant, edition or product of the brand (e.g. a new blueberry flavor when the item is orange; a race-car edition when the item is a Spider-Man edition; the brand's spring rolls when the item is its rice paper; its yogurt juice when the item is its plain juice);
  * the post says it is a NEW or limited flavor/edition without naming it: that is a different variant, not this one;
  * the post is about one of the brand's OTHER items listed under "NOT THIS ITEM";
  * the brand appears only in passing: a bare hashtag with no product talk, a sale or store-promotion post listing many products (unless it names this exact item), or news about the company;
  * the brand word means something else (an ordinary word, a person's name, a K-pop group or idol, a restaurant, a film or book title), or the post is about a different brand.

Rules:
- Judge only from the text given. Do not assume what a video shows.
- Brand names may be misspelled (Cosy/Cozy), written in Thai or Vietnamese script, or appear only as hashtags; those still count when the post is about the product.
- A post that USES this item in a recipe, drink mix or menu is about it ONLY when it names this item: "coffee mixed with Deedo Sainamphueng orange juice" is exact. A recipe that uses the brand without naming this flavor/variant is reject, not close: it is no evidence for any one flavor. A crumble, topping or flavour inspired by the brand is not the item.
- "close" is for posts ABOUT the brand's product itself (a review, ad, unboxing, article) that leave the flavor unstated.
- When this item has NO flavor/variant (a plain product), the brand's seasoned, flavored or snack version of that same product is "close", not "reject" — e.g. the brand's shrimp-salt seasoned rice paper when the item is its plain rice paper. Only a different product type (spring rolls, noodles, a different food) is "reject".
- A word that matches the flavor but describes something else (e.g. a separate slice of cheese, the fruit itself, another product's spice level) is not the flavor.
- Keep "reason" to one short sentence.

Reply with JSON only, in this order — decide the verdict AFTER writing the reason, and make it agree with the reason:
{"reason": "one short sentence: what the post is about and which rule applies",
 "matched_content_item": "the product name as written in the post; keep native script and add English in parentheses when it is not English",
 "verdict": "exact" | "close" | "reject"}"""


def judge_user_prompt(item: dict, post: dict, evidence: dict) -> str:
    """item: brand/product/flavor fields (+ optional _siblings, the brand's other
    promo items); post: channel/title/text; evidence: classify()."""
    flavor = item.get("flavor_variant") or "(none — this item has no flavor/variant)"
    lines = [
        "PROMO ITEM",
        f"  promo description: {item.get('promo_description')}",
        f"  catalog description: {item.get('item_full_description') or '-'}",
        f"  brand: {item.get('brand')}",
        f"  product: {item.get('product')}",
        f"  flavor/variant: {flavor}",
        f"  pack format: {item.get('pack_format') or '-'}",
    ]
    if item.get("_siblings"):
        lines.append("  NOT THIS ITEM (the same brand's other items on this promo):")
        lines += [f"    - {s}" for s in item["_siblings"]]
    lines += [
        "",
        "KEYWORDS FOUND IN THE TEXT",
        f"  brand: {evidence.get('brand_hit') or '-'}",
        f"  product: {evidence.get('product_hit') or '-'}",
        f"  flavor: {evidence.get('flavor_hit') or '-'}",
        "",
        f"POST ({post.get('channel') or 'unknown channel'})",
        str(post.get("text") or "")[:2500],
    ]
    return "\n".join(lines)


def judge(client, model: str, item: dict, post: dict, evidence: dict, max_tokens: int = 800) -> dict | None:
    """One judge call. Returns {verdict, matched_content_item, reason} or None
    when the reply could not be parsed twice (the caller leaves that pair
    unjudged so the next run retries it, rather than storing a guess).
    800 tokens: at 300, a Thai product name plus reason was cut off mid-JSON on
    ~5% of October's candidates."""
    data = None
    for _ in range(2):
        resp = client.messages.create(
            model=model, max_tokens=max_tokens, system=JUDGE_INSTRUCTIONS,
            messages=[{"role": "user", "content": judge_user_prompt(item, post, evidence)}],
        )
        data = extract_json("".join(getattr(b, "text", "") for b in resp.content))
        if isinstance(data, dict) and str(data.get("verdict", "")).lower() in ("exact", "close", "reject"):
            break
    if not isinstance(data, dict) or str(data.get("verdict", "")).lower() not in ("exact", "close", "reject"):
        return None
    return {
        "verdict": str(data["verdict"]).lower(),
        "matched_content_item": str(data.get("matched_content_item") or "")[:300] or None,
        "reason": str(data.get("reason") or "")[:500] or None,
    }


def judge_majority(client, model: str, item: dict, post: dict, evidence: dict, votes: int = 3) -> dict | None:
    """judge() `votes` times and keep the majority verdict, with the reason and
    product name of the first vote that agrees. Measured on October's 128
    candidates, a single call changed its verdict on 3 of them across three runs
    (all borderline "brand named, flavor not" posts); the model endpoint takes no
    temperature, so voting is the lever. No majority (three different answers)
    -> reject: a split judge is not evidence. Returns None if fewer than half the
    votes parsed, so the pair is retried next run."""
    votes = max(1, votes)
    results = [r for r in (judge(client, model, item, post, evidence) for _ in range(votes)) if r]
    if not results or len(results) * 2 < votes:
        return None
    tally = {}
    for r in results:
        tally[r["verdict"]] = tally.get(r["verdict"], 0) + 1
    verdict, count = max(tally.items(), key=lambda kv: kv[1])
    if len(results) > 1 and count * 2 <= len(results):
        verdict = "reject"
    chosen = next((r for r in results if r["verdict"] == verdict), results[0])
    return {**chosen, "verdict": verdict, "votes": ",".join(r["verdict"] for r in results)}


# ─────────────────────────────────────────────────────────────────────────────
# Backend I/O (DuckDB locally, Spark on Databricks)
# ─────────────────────────────────────────────────────────────────────────────

def get_spark():
    try:
        return spark  # noqa: F821 — global on Databricks
    except NameError:
        from pyspark.sql import SparkSession
        return SparkSession.builder.getOrCreate()


def query(backend: str, sql: str, duckdb_path: str | None = None) -> list[dict]:
    """Rows as dicts. On DuckDB the relation names are the local schemas
    (ust_staging.x); on Databricks pass fully-qualified names."""
    if backend == "databricks":
        return [r.asDict(recursive=True) for r in get_spark().sql(sql).collect()]
    import duckdb
    path = duckdb_path or str(find_project_root() / LOCAL_DUCKDB_PATH)
    con = duckdb.connect(path, read_only=True)
    try:
        return con.sql(sql).df().to_dict("records")
    finally:
        con.close()


def read_local_parquet(path: Path) -> list[dict]:
    if not Path(path).exists():
        return []
    import pandas as pd
    return pd.read_parquet(path).to_dict("records")


def append_records(backend: str, records: list[dict], local_path: Path, dbx_table: str, columns: list[str]):
    """Append rows. Every value is written as a string (or None) so the landing
    table stays type-robust; the dbt staging model casts. Same convention as
    parse_mentions.py."""
    if not records:
        return
    rows = [{c: (None if r.get(c) is None else str(r.get(c))) for c in columns} for r in records]
    if backend == "databricks":
        from pyspark.sql.types import StructType, StructField, StringType
        schema = StructType([StructField(c, StringType(), True) for c in columns])
        (get_spark().createDataFrame(rows, schema=schema)
            .write.format("delta").mode("append").option("mergeSchema", "true")
            .saveAsTable(dbx_table))
        return
    import pandas as pd
    local_path = Path(local_path)
    local_path.parent.mkdir(parents=True, exist_ok=True)
    df = pd.DataFrame(rows, columns=columns)
    if local_path.exists():
        df = pd.concat([pd.read_parquet(local_path), df], ignore_index=True)
    df.to_parquet(local_path, index=False)


# The landing tables the scripts write and dbt reads (all-string columns; the
# stg_promo__* models cast). Listed once here so a script and its staging model
# cannot disagree about a column name.
LANDING = {
    "item_terms_draft": {
        "dbx": f"{SOCIAL_SCHEMA}.promo_item_terms_draft",
        "file": "item_terms_draft.parquet",
        "columns": ["item_no", "brand", "product", "flavor_variant", "pack_format", "is_branded",
                    "brand_terms", "product_terms", "flavor_terms", "negative_terms",
                    "search_queries", "notes", "drafted_at", "model_version"],
    },
    "social_judgments": {
        "dbx": f"{SOCIAL_SCHEMA}.promo_social_judgments",
        "file": "social_judgments.parquet",
        "columns": ["item_no", "mention_id", "keyword_level", "brand_hit", "product_hit",
                    "flavor_hit", "match_text", "verdict", "judge_votes", "matched_content_item",
                    "reason", "judge_model", "judge_version", "judged_at"],
    },
    "youtube_videos": {
        "dbx": f"{SOCIAL_SCHEMA}.promo_youtube_videos",
        "file": "youtube_videos.parquet",
        "columns": ["promo_month", "item_no", "video_id", "search_query", "query_rank", "title",
                    "description", "tags", "channel_title", "channel_id", "published_at",
                    "view_count", "like_count", "comment_count", "duration", "is_short",
                    "keyword_level", "brand_hit", "product_hit", "flavor_hit", "match_text",
                    "verdict", "judge_votes", "matched_content_item", "reason", "judge_model",
                    "judge_version", "searched_at"],
    },
}


def landing_path(name: str, root=None) -> Path:
    return local_data_root(root) / "promo" / LANDING[name]["file"]


def ensure_landing(backend: str, root=None) -> None:
    """Create any landing table that does not exist yet, empty, and add any
    column LANDING has gained since it was created — so the dbt staging views
    (which name every column) can always be built, including before a script has
    written its first row (DuckDB binds read_parquet at view-creation time and
    fails on a missing file or column). Safe to call every run."""
    import pandas as pd
    for name, spec in LANDING.items():
        if backend == "databricks":
            spark = get_spark()
            cols = ", ".join(f"`{c}` string" for c in spec["columns"])
            spark.sql(f"create table if not exists {spec['dbx']} ({cols}) using delta")
            have = {f.name for f in spark.table(spec["dbx"]).schema.fields}
            missing = [c for c in spec["columns"] if c not in have]
            if missing:
                spark.sql(f"alter table {spec['dbx']} add columns ("
                          + ", ".join(f"`{c}` string" for c in missing) + ")")
                print(f"  added {missing} to {spec['dbx']}")
            continue
        path = landing_path(name, root)
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            pd.DataFrame({c: pd.Series(dtype="string") for c in spec["columns"]}).to_parquet(path, index=False)
            print(f"  created empty {path}")
            continue
        df = pd.read_parquet(path)
        missing = [c for c in spec["columns"] if c not in df.columns]
        if missing:
            for c in missing:
                df[c] = pd.Series([None] * len(df), dtype="string")
            df.to_parquet(path, index=False)
            print(f"  added {missing} to {path}")


def none_if_nan(v):
    try:
        import math
        if v is None or (isinstance(v, float) and math.isnan(v)):
            return None
    except Exception:
        pass
    return v
