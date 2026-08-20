"""Resolve trending social CONCEPTS to WMS SKUs (step ③, OUT-OF-BAND from dbt).

Sibling of scripts/enrich_mentions.py — SAME LLM setup (Databricks-hosted Claude
via the workspace serving endpoint, ambient auth on the databricks backend). dbt
stays deterministic and never calls the LLM; this writes a table dbt then reads.
GATED: only the top-N ranked concepts are resolved, so the long tail costs nothing.

THREE PASSES, because BOTH kinds of error cost something here. One model proposing
matches will pad a basket with plausible-but-wrong items ("DF TOMYUM PASTE" under a
rice-noodle-curry dish) — and it will also miss a product we plainly stock, which is
worse, because "we don't carry this" sends someone to source it.
  ① PROPOSE — read the mention snippets + the catalog, classify, pick items.
  ② VERIFY  — a SECOND, INDEPENDENT call seeing only the concept, the same snippets,
              and the candidates rendered with their AUTHORITATIVE catalog names,
              prompted to REFUTE each one. What it can't defend is dropped, and ITS
              confidence (not the proposer's) is what the mart's
              social_resolve_min_confidence floor gates on. A failed verify call
              writes NOTHING — the concept stays unresolved and is retried next run
              rather than shipping an unverified guess.
  ③ RECOVER — only when ② leaves "none". Verify can only SUBTRACT, so a proposer miss
              is otherwise unrecoverable and surfaces as a false "nothing like this in
              stock". This pass gets the whole catalog again plus what was already
              ruled out, hunts for the plain/base form and warehouse-shorthand names,
              and ITS candidates go back through ② — recall improves, precision does
              not move, because nothing reaches the table unreviewed.
The proposer's self-rated confidence is kept alongside as proposer_confidence, so
the two can be compared (v4 clustered at 0.72 — just above a 0.70 floor, which
made the floor inert).

WHY IT READS MENTION SNIPPETS (learned 2026-07-30): a bare token like "pork" or
"7-eleven" has no meaning on its own — "pork" might be หมูกระจก (crispy pork jerky)
or หมูกระทะ (Thai BBQ), never "pork skin". So for each trending concept the model
is given a few REAL mention snippets (title/content + the AI arrays) and must:
  1. CANONICALISE   — one display name, merging cross-language/spelling variants
                      (som tam / ส้มตำ -> "Som Tam (green papaya salad)").
  2. CLASSIFY       — carried / substitute / basket / none (see INSTRUCTIONS).
  3. MATCH SEMANTICALLY against the real catalog, reading the context — NOT by
     string overlap.
Snippets are therefore load-bearing: a concept with zero snippets is a bare token
and the model WILL guess. _concept_key() must stay byte-identical to how
int_social_concept_trends builds concept_norm or the lookup silently misses and
every affected concept is resolved blind — see the SQL PARITY note below.

TWO CONCEPT CLASSES, ranked separately upstream, both reaching this script:
'dish' (from mentioned_dishes) and 'item' (from mentioned_products — branded or
packaged goods a grocery/restaurant could order). An 'item' is already meant to be
SKU-shaped, so for those the model is pushed to settle 'carried' before falling
back to an ingredient basket. The gate resolves the CURRENT week's top-N of each;
historical weeks reuse the same resolution rows, since a concept->SKU mapping is
timeless.

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
from datetime import datetime, timedelta, timezone
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
PROMPT_VERSION = "v7"                    # v5 = propose + independent VERIFY pass; deglossed snippet keys
                                         # v6 = SECOND LOOK on a "none": recall matters as much as
                                         #      precision here, because a false "we don't carry this"
                                         #      sends someone to source a product we already sell
                                         # v7 = board-level grouping is REVIEWED before it is applied
                                         #      (v6's first run merged 3 wrong out of 4)
_CURRENT_VERSION = f"{MODEL}/{PROMPT_VERSION}"  # stamp on each row; drives version-aware re-resolve
MAX_TOKENS = 700
VERIFY_MAX_TOKENS = 1200                 # per-candidate verdicts + reasons
TEMPERATURE = 0.0                        # matching is a judgment, not a creative task — same
                                         # concept must resolve the same way run to run
CONCURRENCY = 4
MAX_RETRIES = 8
MAX_ATTEMPTS = 2
BATCH_SIZE = 100
MAX_RECOMMENDATIONS = 5                  # hard cap after verification (basket rule says 2-5)
# gate: resolve concepts at trend_rank <= this. Reads dbt_project.yml's
# social_trend_top_n — the same var the mart uses — instead of a second,
# independent hardcoded "20" that could quietly drift from it.
TOP_N = _dbt_var("social_trend_top_n", 20)
SNIPPETS_PER_CONCEPT = 8               # representative mentions shown to the model
SNIPPET_CHARS = 400
SNIPPET_WINDOW_DAYS = 28               # days of mention context behind the ranked week — see
                                       # _snippet_window(); wider than the one-week ranking grain
                                       # on purpose, so a mid-week run can't starve a concept

LOCAL_DUCKDB_PATH = "dev.duckdb"
LOCAL_RESOLUTION_PATH = "data/mock/mentionlytics/concept_resolution.parquet"

DBX_TRENDS_TABLE = "ust_databricks.ust_intermediate.int_social_concept_trends"
DBX_ITEMS_TABLE = "ust_databricks.ust_intermediate.int_jdawms_items_active"
DBX_FCT_TABLE = "ust_databricks.ust_facts.fct_social_mentions"
DBX_RESOLUTION_TABLE = "ust_databricks.social.concept_resolution"
DUCKDB_TRENDS_REL = "ust_intermediate.int_social_concept_trends"
DUCKDB_ITEMS_REL = "ust_intermediate.int_jdawms_items_active"
DUCKDB_FCT_REL = "ust_facts.fct_social_mentions"

INSTRUCTIONS = """You map a TRENDING FOOD CONCEPT from Thai/Vietnamese social \
listening to products in a food distributor's warehouse catalog. You are given \
the catalog (part numbers, names, families) as reference, then ONE concept at a \
time together with a few REAL social-mention snippets that mention it.

READ THE SNIPPETS to understand what people are actually talking about before you \
decide — a word alone is ambiguous ("pork" may be crispy pork jerky หมูกระจก or a \
BBQ, never "pork skin"). If NO snippets are shown, you are looking at a bare token \
with no context: do NOT guess a basket from the token's literal words — return \
"none" with low confidence and let a human look at it.

The "Seen as" line says which ranking board the concept came from: "dish" = a dish \
people talked about; "item" = a SELLABLE PRODUCT — the extraction already judged \
it to be a branded or packaged/processed good a grocery or restaurant could order, \
not a raw commodity. For an "item", work hard to settle "carried" or "substitute" \
before falling back to a basket: an ingredient basket under something that is \
itself a product is almost always the wrong answer, and the whole reason that \
board exists is to surface things a rep can sell as-is. A concept can be both.

Then return ONE JSON object — no markdown, no prose — exactly:
{
  "canonical_label": string,       // one clean display name; merge language/spelling
                                   //   variants (som tam / ส้มตำ -> "Som Tam (green papaya salad)").
                                   //   ONE dish, not a list of guesses — never
                                   //   "A (B / C)" where B and C are different dishes.
  "concept_type": string,          // "dish" | "category" | "ingredient" | "product" | "brand"
  "result_type": string,           // see below
  "matched_prtnum": string|null,   // only for "carried"
  "recommended_prtnums": [string], // for "substitute"/"basket"; [] otherwise. Max 5.
  "recommended_item_names": [string], // catalog item_name COPIED VERBATIM, SAME ORDER
                                   //   as recommended_prtnums — do not paraphrase or
                                   //   tidy them; a name that disagrees with its
                                   //   part number is treated as an error.
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

BEFORE YOU CONCLUDE "none", CHECK THE PLAIN FORM. A flavoured or branded variant being \
wrong does not mean the product is absent: "sriracha mayo" is not "mayonnaise", but a \
plain Japanese mayonnaise in the catalog IS. Also look past warehouse shorthand — the \
catalog is written in abbreviations and brand-led names, so the item you want may not \
read like the words in the concept. Saying we carry nothing when we do carry it is the \
most expensive mistake available here, because it tells the sales team to go and source \
something we already sell.

PREFER "none" OR AN EMPTY BASKET OVER A WEAK MATCH. If no catalog item is genuinely \
the same kind of food, return "none" — do NOT stretch. Three hard rules: a substitute \
must be something a shopper would actually accept in place of the trending item; a \
basket item must be a defining ingredient of THAT dish; and never list two part \
numbers for the same product (the catalog holds duplicate names — pick one). NEVER \
include generic, tangential, or different-cuisine items (do NOT put green jackfruit \
or Korean beef bulgogi under a Thai/Vietnamese dish just because they are food), and \
never include an all-purpose staple every kitchen already buys (plain rice, sugar, \
salt, cooking oil) as a "defining" ingredient. Set match_confidence to reflect \
precision — high ONLY when the items clearly define the dish; lower it when the \
basket is loose. A low value is fine and far better than a confident-looking wrong \
match.

Rules: every prtnum you output MUST exist in the catalog exactly; names line up \
1:1 with prtnums. Judge on MEANING across Thai / Vietnamese / English, never on \
keyword overlap. This applies to brand names too: a snippet's "brands" field is a \
hint about WHERE people saw the item, not a match key — a shared brand/word between \
a snippet and a catalog item name is meaningless unless the underlying PRODUCT is \
genuinely the same kind of food (a brand called "XYZ" on a banh mi post does not \
make "XYZ Noodles" a match)."""

GROUP_INSTRUCTIONS = """You are given ALL of this week's trending food concepts from \
Thai/Vietnamese social listening, in one list. Some of them are THE SAME THING under a \
different name, and the board currently shows them as separate entries — splitting one \
trend's mentions in two and wasting a slot. Group those together.

Return ONE JSON object — no markdown, no prose:
{"groups": [ {"primary": string, "members": [string], "label": string} ]}
  primary  the raw concept text that best represents the group; MUST be one of members
  members  the raw concept texts in the group, copied EXACTLY as given
  label    one clean display name for the group

LIST ONLY THE GROUPS THAT HAVE TWO OR MORE MEMBERS. Anything you do not mention is \
assumed to stand alone, which is the normal case — most concepts are not duplicates of \
anything, and `"groups": []` is a perfectly good answer. Do NOT echo back the concepts \
you are leaving alone: there is no need, and a long reply risks being cut off before it \
is valid JSON.

APPLY THIS ONE TEST, and nothing else. Ask: does either text carry a word that NARROWS \
what is being referred to — a brand, a variety, a flavour, a preparation, a cut, a \
region? If yes, THEY ARE DIFFERENT. Only merge when the two texts denote the identical \
thing, one being a translation, transliteration, or spelling variant of the other.

Worked through, so the test is unambiguous:
  "som tam" / "ส้มตำ"                 SAME — transliteration, nothing narrowed
  "banh khot" / "bánh khọt"           SAME — diacritics only
  "matcha" / "matcha powder"          SAME — "powder" is the form matcha comes in, it
                                      does not narrow which thing is meant
  "มาม่า" / "instant noodles"          DIFFERENT — มาม่า (Mama) is a BRAND. A brand always
                                      narrows. Never merge a brand into a category.
  "น้ำพริก" / "น้ำพริกแซ่บ"              DIFFERENT — "แซ่บ" narrows it to one variety
  "ก๋วยเตี๋ยว" / "ก๋วยเตี๋ยวเรือ"          DIFFERENT — "เรือ" (boat) narrows it to one dish
  "fried chicken" / "grilled chicken" DIFFERENT — the preparation narrows it
  "ice cream" / "frozen yogurt"       DIFFERENT — merely the same category
  "pork" / "crispy pork"              DIFFERENT — "crispy" narrows it

A shared head word is NOT evidence of sameness. Most of the pairs above share one, and \
almost all of them are different things. If one text is a longer version of the other, \
assume the extra words matter and DO NOT MERGE unless those words only restate the same \
thing.

Also never merge across boards: each concept is tagged [dish] or [item], and a group \
must be entirely one or the other even for identical text.

WHEN IN DOUBT, LEAVE THEM SEPARATE. A wrong merge fuses two real trends into one and \
buries the more specific signal — a brand disappearing inside a category is the exact \
failure this must avoid. A missed merge only costs a duplicate row, which is visible and \
harmless by comparison. Merging nothing is a good answer."""


MERGE_REVIEW_INSTRUCTIONS = """You are reviewing proposed merges of trending food \
concepts. Another model claimed each pair below refers to the SAME thing. Your job is to \
REFUTE that wherever it does not hold. Default to REFUSING the merge.

Refuse whenever either text carries a word that NARROWS what is meant — a brand, a \
variety, a flavour, a preparation, a cut, a region. A brand ALWAYS narrows ("มาม่า" is \
Mama, a brand, and is not "instant noodles"). A qualifier ALWAYS narrows ("น้ำพริกแซ่บ" is \
one variety of "น้ำพริก"; "ก๋วยเตี๋ยวเรือ" is one dish within "ก๋วยเตี๋ยว"). Sharing a head word \
is not sameness.

Accept ONLY when the two texts denote the identical thing — a translation, \
transliteration, diacritic or spelling variant, or a form of the same substance \
("matcha" / "matcha powder").

Return ONE JSON object, no prose:
{"verdicts": [ {"primary": string, "member": string, "same": boolean, "reason": string} ]}
one entry per proposed pair, copying primary and member EXACTLY as given, reason <= 100 \
chars. A merge you do not explicitly accept is discarded, so silence rejects."""

RECOVERY_INSTRUCTIONS = """You are a SECOND-CHANCE CATALOG SEARCH, and you exist to \
stop one specific mistake.

A first pass looked at this trending concept and concluded we stock nothing suitable — \
either it proposed nothing, or a reviewer threw out everything it proposed. That answer \
reaches the sales team as "we do not carry this and have nothing like it", which sends \
someone to source a product we may already sell. Observed for real: a "mayonnaise" \
trend was reported as not-carried because the first pass offered only a SRIRACHA mayo \
(correctly rejected as a flavoured variant) and never noticed the plain Japanese \
mayonnaise sitting in the catalog.

So search the WHOLE catalog again, properly, and specifically for:
  - THE PLAIN OR BASE FORM. A wrong flavoured variant says nothing about whether the
    plain product exists.
  - THE SAME PRODUCT UNDER WAREHOUSE SHORTHAND — abbreviations, a brand-led name, a
    different word order, a pack-size suffix. The catalog is not written the way people
    post.
  - A GENUINE SUBSTITUTE: the same kind of food a buyer would accept instead. We would
    rather offer a real alternative than nothing.

You are told which part numbers were ALREADY RULED OUT, and why. Respect those verdicts \
— do NOT offer them again. Find something else, or nothing.

Return ONE JSON object in exactly the same shape as the matcher:
{
  "canonical_label": string,
  "concept_type": string,
  "result_type": string,           // "carried" | "substitute" | "basket" | "none"
  "matched_prtnum": string|null,
  "recommended_prtnums": [string],
  "recommended_item_names": [string],
  "match_confidence": number
}

Every prtnum MUST exist in the catalog exactly. If after a real search nothing genuinely \
fits, return "none" — an honest none is still the right answer, and whatever you do \
return still has to survive review. This pass exists to make sure the none is honest, \
not to manufacture a match."""

VERIFY_INSTRUCTIONS = """You are a STRICT REVIEWER. Another model proposed a match \
between a TRENDING FOOD CONCEPT from Thai/Vietnamese social listening and items in \
a food distributor's catalog. Your job is to REFUTE what does not hold up, not to \
be agreeable. A rejected item costs us nothing; a wrong one goes onto a board the \
sales team acts on, so DEFAULT TO REJECTING whenever you are unsure.

You see the concept, the REAL mention snippets behind it, and each candidate with \
its AUTHORITATIVE catalog name (the proposer's own wording is deliberately hidden — \
judge the item that part number actually is). If no snippets are shown, you have no \
evidence of what people meant: reject everything and return "none".

Keep a candidate ONLY if it passes the test for how it was proposed:
  - "matched" (carried): this item IS the trending thing itself, ready to sell —
    not an ingredient of it, not a related product.
  - "recommended" as a substitute: someone who wanted the trending item would
    accept THIS instead — the same kind of food.
  - "recommended" as a basket item: it is a CORE, DEFINING ingredient of THIS
    specific dish, from the SAME cuisine — the dish is not that dish without it.

REJECT, always:
  - a different cuisine's ingredient placed under this dish;
  - a generic all-purpose staple (plain rice, sugar, salt, cooking oil, plain flour)
    dressed up as "defining";
  - a merely adjacent or thematically similar item ("Thai food, so fish sauce");
  - an item you cannot confidently identify from its catalog name;
  - a near-duplicate of a candidate you already kept (same product, another part
    number) — keep exactly one;
  - anything where the concept itself is too vague to pin down.

Return ONE JSON object — no markdown, no prose — exactly:
{
  "verdicts": [                    // one entry per candidate, same part numbers you were given
    {"prtnum": string, "keep": boolean, "reason": string}   // reason <= 120 chars, concrete
  ],
  "result_type": string,           // final call: "carried" | "substitute" | "basket" | "none".
                                   //   "none" if you kept nothing.
  "canonical_label": string,       // the proposer's display name, CORRECTED if it is wrong or
                                   //   merges several different dishes into one label.
  "confidence": number             // 0.0–1.0 — calibrated certainty in the items you KEPT.
                                   //   This is the number a 0.7 cutoff is applied to, so do not
                                   //   inflate it: 0.9+ only when the kept items unambiguously
                                   //   define the concept and the snippets prove the meaning.
}"""

_REQUIRED_KEYS = {
    "canonical_label", "concept_type", "result_type", "matched_prtnum",
    "recommended_prtnums", "recommended_item_names", "match_confidence",
}
_VALID_RESULT = {"carried", "substitute", "basket", "none"}
_MATCHED_RESULTS = {"carried", "substitute", "basket"}


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


# Whether the serving proxy accepts `temperature`. Determinism matters here (the
# same concept must not resolve differently run to run), but the Databricks
# Anthropic-compatible proxy is a moving target and a rejected parameter would
# otherwise fail EVERY concept in the run. So: try it once, and if the endpoint
# objects to the parameter specifically, fall back to default sampling for the
# rest of the run instead of dying. Benign race under the thread pool — the worst
# case is a couple of extra attempts before the flag settles.
_TEMPERATURE_SUPPORTED = True

# per-stage token/call counters, reported once at the end by report_usage().
# Incremented from the thread pool; a lost update under contention would only skew
# a diagnostic, never a result.
_USAGE = defaultdict(lambda: {'calls': 0, 'input': 0, 'cache_read': 0,
                             'output': 0, 'truncated': 0})


def _create_message(client, **kwargs):
    global _TEMPERATURE_SUPPORTED
    if _TEMPERATURE_SUPPORTED:
        try:
            return client.messages.create(temperature=TEMPERATURE, **kwargs)
        except Exception as e:
            if "temperature" not in str(e).lower():
                raise
            _TEMPERATURE_SUPPORTED = False
            print("  NOTE: serving endpoint rejected `temperature`; continuing with "
                  "the endpoint default (results may vary run to run).", file=sys.stderr)
    return client.messages.create(**kwargs)


# ─────────────────────────────────────────────────────────────────────────────
# Backend I/O
# ─────────────────────────────────────────────────────────────────────────────

def _top_concepts_sql(trends_rel, top_n):
    """Concepts on the CURRENT week's board, either class.

    int_social_concept_trends is a weekly series of boards, so it holds every
    concept that was ever top-N over social_trend_history_weeks. Scoping to the
    latest week keeps the resolve set at ~top_n per class instead of half a year of
    them — historical rows still get their labels and SKUs, because the resolution
    joins on concept_norm alone and a concept->SKU mapping is timeless.

    Grouped because one concept can be BOTH a dish and an item (the same folded
    string in two rank spaces) and the resolution is keyed on concept_norm alone.
    The classes come back as two flags rather than a string_agg because Spark SQL
    has no string_agg — _class_hint() turns them into the prompt's "Seen as". And
    mention_count is max(), not sum(): summing across overlapping trailing windows
    is not a count of anything.
    """
    return f"""
        select concept_norm,
               max(case when concept_class = 'dish' then 1 else 0 end) as is_dish,
               max(case when concept_class = 'item' then 1 else 0 end) as is_item,
               max(mention_count) as mention_count
        from {trends_rel}
        where trend_rank <= {top_n}
          and week_start = (select max(week_start) from {trends_rel})
        group by concept_norm
    """


def _class_hint(concept):
    """"Seen as" line for the prompt. 'item' means the concept came from the
    ingredient/product board — a thing we might stock directly — which is a nudge
    toward carried/substitute over a basket of ingredients."""
    classes = [name for name, key in (("dish", "is_dish"), ("item", "is_item"))
               if concept.get(key)]
    return ", ".join(classes) or "unknown"


def _latest_week_sql(trends_rel):
    """End of the CURRENT board's calendar week — the anchor for the snippet
    window below."""
    return f"""
        select max(week_end) as week_end from {trends_rel}
    """


def _snippet_window(week_end_str, days=SNIPPET_WINDOW_DAYS):
    """Snippet evidence spans the last `days` ending at the board's week, NOT the
    single ranked week. This is window #5 of five — the set, and why they differ, is
    in models/docs/_social_windows.md.

    The two windows answer different questions and must not be tied together. The
    RANKING window is one calendar week because that's the reporting period. The
    SNIPPET window only has to establish what a token MEANS, and a mid-week run
    leaves the latest week with a day or two of posts — few enough to leave a
    concept with no usable snippets, which is precisely how a bare token gets
    guessed at (see the module docstring). A month of context fixes that while
    still being recent enough that the token hasn't drifted.
    """
    if not week_end_str:
        return None, None
    end = datetime.strptime(week_end_str[:10], "%Y-%m-%d").date()
    return (end - timedelta(days=days - 1)).isoformat(), end.isoformat()


def _snippet_source_sql(fct_rel, window_start=None, window_end=None):
    """Mentions carrying the dish array + text, for snippet buckets.

    SCOPED TO THE SNIPPET WINDOW (see _snippet_window — the last few weeks ending
    at the ranked week, NOT the ranked week itself): the concept is trending NOW, so
    the evidence must be what people are saying now — an all-time query can fill
    every slot with a loud post from months ago that made the token mean something
    else — but one calendar week is too little to reliably explain a token, and a
    mid-week run would leave almost nothing.

    BOTH ranked streams are required. int_social_concept_trends ranks two classes —
    dishes from mentioned_dishes and sellable products from mentioned_products — so a
    dish-only filter would leave every ITEM concept with zero snippets, resolved from
    a bare token. That is the exact failure the deglossing fix removed; it must not
    come back through the new class. `ingredients` and `brands` are NOT match keys:
    nothing is ranked from them, so a token that folds to a concept's key can only
    pull in an off-topic post — and the prompt already tells the model a shared brand
    token is not a match. Both stay in the snippet BODY as context, where ingredients
    are genuinely useful for judging an ingredient basket.
    """
    where = ["(mentioned_dishes is not null or mentioned_products is not null)"]
    if window_start and window_end:
        where.append(f"posted_date between date '{window_start}' and date '{window_end}'")
    return f"""
        select mention_id, title, content,
               mentioned_dishes, mentioned_products, ingredients, brands,
               coalesce(total_engagement, 0) as engagement
        from {fct_rel}
        where {' and '.join(where)}
    """


def _current_rows_sql(table, version):
    """Current-version resolution rows, deduped the same way staging does
    (latest resolved_at per concept). Read so alias harmonisation (below) can
    see concepts resolved in EARLIER runs, not just this batch."""
    return f"""
        select * from (
            select *, row_number() over (
                partition by concept_norm order by resolved_at desc) as _rn
            from {table}
            where model_version = '{version}'
        ) where _rn = 1
    """


def _as_date_str(v):
    """Date -> 'YYYY-MM-DD', or None when there is no date.

    The None case is NOT hypothetical: `select max(week_end)` over an EMPTY trends
    table returns one row holding NULL, which pandas hands back as NaT — so a
    `len(rows)` guard passes and NaT.strftime() then raises ValueError. That crashed
    the script with a stack trace instead of reporting "nothing to resolve" whenever
    it ran before int_social_concept_trends had been built."""
    if v is None:
        return None
    try:
        if v != v:            # NaN / NaT are never equal to themselves
            return None
    except Exception:
        pass
    try:
        return v.strftime("%Y-%m-%d")
    except (AttributeError, ValueError):
        s = str(v).strip()
        return None if s in ("", "NaT", "None", "nan", "NaN") else s[:10]


def read_all(backend, top_n, duckdb_path, version=_CURRENT_VERSION):
    """Return (new_concepts, snippets_by_concept, catalog, existing_rows)."""
    if backend == "databricks":
        spark = _get_spark()
        concepts = [r.asDict() for r in
                    spark.sql(_top_concepts_sql(DBX_TRENDS_TABLE, top_n)).collect()]
        wb = spark.sql(_latest_week_sql(DBX_TRENDS_TABLE)).collect()
        w_start, w_end = _snippet_window(_as_date_str(wb[0][0]) if wb else None)
        mentions = [r.asDict() for r in
                    spark.sql(_snippet_source_sql(DBX_FCT_TABLE, w_start, w_end)).collect()]
        catalog = [r.asDict() for r in spark.table(DBX_ITEMS_TABLE)
                   .select("prtnum", "item_name", "item_short_name", "item_family").collect()]
        try:
            # VERSION-AWARE: only concepts resolved at the CURRENT model+prompt
            # version count as done. Bumping PROMPT_VERSION drops every stale row
            # out of this set, so the next run re-resolves it automatically — no
            # manual truncate needed, still incremental (only stale + new).
            existing = [r.asDict() for r in
                        spark.sql(_current_rows_sql(DBX_RESOLUTION_TABLE, version)).collect()]
        except Exception:
            existing = []
    else:
        import duckdb
        con = duckdb.connect(duckdb_path, read_only=True)
        concepts = con.sql(_top_concepts_sql(DUCKDB_TRENDS_REL, top_n)).df().to_dict("records")
        wb = con.sql(_latest_week_sql(DUCKDB_TRENDS_REL)).df()
        w_start, w_end = _snippet_window(_as_date_str(wb["week_end"][0]) if len(wb) else None)
        mentions = con.sql(
            _snippet_source_sql(DUCKDB_FCT_REL, w_start, w_end)
        ).df().to_dict("records")
        catalog = con.sql(
            f"select prtnum, item_name, item_short_name, item_family from {DUCKDB_ITEMS_REL}"
        ).df().to_dict("records")
        con.close()
        try:
            import duckdb as _d
            existing = _d.connect().sql(
                _current_rows_sql(f"read_parquet('{LOCAL_RESOLUTION_PATH}')", version)
            ).df().to_dict("records")
        except Exception:
            existing = []

    if not concepts and not w_end:
        print("int_social_concept_trends is EMPTY — nothing to resolve. Build it first: "
              "dbt build --select +int_social_concept_trends", file=sys.stderr)

    # Every string the enrichment ever called a BRAND, folded to concept keys. Used as a
    # hard guard on grouping below: a brand must never be folded into a category. This is
    # the one part of that judgment that needs no model — the brands were already
    # extracted.
    brand_keys = {_concept_key(b) for m in mentions
                  for b in _raw_list(m.get("brands"))}

    wanted = {c["concept_norm"] for c in concepts}
    snippets = bucket_snippets(mentions, wanted)
    resolved = {r.get("concept_norm") for r in existing}
    new = [c for c in concepts if c["concept_norm"] not in resolved]
    print(f"snippet window: {w_start} .. {w_end}  "
          f"({len(mentions)} mentions naming a dish or a product, "
          f"{len(brand_keys)} distinct brands seen)")
    return new, snippets, catalog, existing, brand_keys


# ─────────────────────────────────────────────────────────────────────────────
# SQL PARITY — concept keys must match int_social_concept_trends EXACTLY
# ─────────────────────────────────────────────────────────────────────────────
# concept_norm is built in SQL as fold_concept(strip_parenthetical_gloss(dish)),
# so a key built here with only the fold step MISSES every dish string that
# carries a trailing gloss — and the LLM appends one often ("ข้าวมัน (rice with
# chicken fat)"). That was a real, silent bug (fixed 2026-08-18): those concepts
# matched no snippets at all, the prompt said "(no snippets found)", and the model
# resolved a bare Thai token against 2.5k abbreviated catalog names — which is
# exactly how "DF TOMYUM PASTE" ended up under a rice-noodle-curry dish. Both
# steps are mirrored below and both are guarded by
# scripts/check_fold_consistency.py.

# Copied character-for-character from macros/fold_concept.sql's translate()
# call, so the two can't silently drift apart again. A general Unicode
# NFKD/combining-mark strip (the previous approach) also strips THAI tone
# marks and vowel signs — Thai combining characters aren't in this table, so
# they must pass through byte-for-byte unchanged, exactly like the SQL side.
_FOLD_FROM = "àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ"
_FOLD_TO = "aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd"
_FOLD_TABLE = str.maketrans(_FOLD_FROM, _FOLD_TO)

# Copied from macros/strip_parenthetical_gloss.sql's default__ regex (DuckDB
# spelling; the databricks__ variant is the same pattern with doubled
# backslashes for its string-literal parser). ONE trailing parenthetical only,
# anchored to end of string — deliberately conservative, same as the macro.
_GLOSS_PATTERN = r"\s*\([^)]*\)$"
_GLOSS_RE = re.compile(_GLOSS_PATTERN)


def _fold(s):
    """Match macros/fold_concept.sql EXACTLY: lower+trim, translate() over the
    same 67 Vietnamese-diacritic characters (+ đ->d), collapse spaces. Thai (and
    anything else not in the table) passes through unchanged, same as the SQL."""
    s = str(s).strip().lower().translate(_FOLD_TABLE)
    return re.sub(" +", " ", s)


def _strip_gloss(s):
    """Match macros/strip_parenthetical_gloss.sql: strip ONE trailing '(...)'."""
    return _GLOSS_RE.sub("", str(s).strip())


def _concept_key(s):
    """The SQL's concept_norm, in Python: strip the trailing gloss, then fold.
    Mirrors int_social_concept_trends' fallback for a concept that is ENTIRELY
    parenthetical — deglossing to '' falls back to the original text rather than
    dropping the row."""
    deglossed = _strip_gloss(s)
    return _fold(deglossed if deglossed else s)


def _raw_list(v):
    """Array column -> list of original (un-normalised) strings. The model reads
    these, so they keep their real casing and diacritics; only the MATCH key is
    folded. duckdb hands back numpy arrays, spark hands back lists."""
    if v is None:
        return []
    try:
        return [str(x).strip() for x in list(v) if x is not None and str(x).strip()]
    except TypeError:
        return []


def _snippet_text(m):
    title = (m.get("title") or "").strip()
    content = (m.get("content") or "").strip()
    if title and content and not content.lower().startswith(title.lower()):
        text = f"{title} — {content}"
    else:
        text = content or title
    return re.sub(r"\s+", " ", text)[:SNIPPET_CHARS]


def bucket_snippets(mentions, wanted):
    """{concept_norm: [snippet_dict, ...]} keeping the most useful few.

    Ordered by (has text, engagement): a caption-less row carries almost no
    evidence, so it must not take a slot from a post that actually says something.
    """
    buckets = defaultdict(list)
    for m in mentions:
        dishes = _raw_list(m.get("mentioned_dishes"))
        products = _raw_list(m.get("mentioned_products"))
        # keys from BOTH ranked streams — dishes feed the 'dish' class, products the
        # 'item' class, and a concept can be in either (or both). NOT ingredients:
        # nothing is ranked from that array, so it would only add false hits.
        hit = {_concept_key(c) for c in dishes + products} & wanted
        if not hit:
            continue
        text = _snippet_text(m)
        snip = {
            "text": text,
            "dishes": dishes,
            "products": products,
            "ingredients": _raw_list(m.get("ingredients")),
            "brands": _raw_list(m.get("brands")),
        }
        eng = m.get("engagement") or 0
        for cn in hit:
            buckets[cn].append((1 if text else 0, eng, snip))
    for cn in list(buckets):
        ranked = sorted(buckets[cn], key=lambda t: (-t[0], -t[1]))
        buckets[cn] = [s for _, _, s in ranked][:SNIPPETS_PER_CONCEPT]
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
        StructType, StructField, StringType, DoubleType, IntegerType, ArrayType,
        TimestampType,
    )
    arr = ArrayType(StringType())
    return StructType([
        StructField("concept_norm", StringType()),
        StructField("canonical_label", StringType()),
        StructField("group_primary", StringType()),
        StructField("group_label", StringType()),
        # LEGACY, always null: canonical_key/alias_of were the label-matching
        # harmonisation that grouping replaced (v6). They are still columns on the
        # existing Delta table, and writing a DataFrame that simply omits them relies
        # on schema evolution filling them — so they are declared here instead and the
        # append matches the table exactly. Drop them from this list once the table
        # has been rebuilt without them.
        StructField("canonical_key", StringType()),
        StructField("alias_of", StringType()),
        StructField("concept_type", StringType()),
        StructField("result_type", StringType()),
        StructField("matched_prtnum", StringType()),
        StructField("recommended_prtnums", arr),
        StructField("recommended_item_names", arr),
        StructField("recommended_reasons", arr),
        StructField("rejected_prtnums", arr),
        StructField("rejected_reasons", arr),
        StructField("name_mismatch_prtnums", arr),
        StructField("match_confidence", DoubleType()),
        StructField("proposer_confidence", DoubleType()),
        StructField("snippet_count", IntegerType()),
        StructField("resolved_at", TimestampType()),
        StructField("model_version", StringType()),
    ])


_RECORD_DEFAULTS = {
    "concept_norm": None, "canonical_label": None, "group_primary": None,
    "group_label": None, "canonical_key": None, "alias_of": None,
    "concept_type": None, "result_type": None,
    "matched_prtnum": None, "recommended_prtnums": [], "recommended_item_names": [],
    "recommended_reasons": [], "rejected_prtnums": [], "rejected_reasons": [],
    "name_mismatch_prtnums": [], "match_confidence": None,
    "proposer_confidence": None, "snippet_count": None, "resolved_at": None,
    "model_version": None,
}


def _coerce_record(row):
    """Normalise a row read back from the resolution table into exactly the
    schema above — an older row may be missing a column and duckdb hands arrays
    back as numpy arrays, neither of which spark.createDataFrame accepts."""
    out = {}
    for k, default in _RECORD_DEFAULTS.items():
        v = row.get(k, default)
        if isinstance(default, list):
            out[k] = _raw_list(v)
        else:
            out[k] = None if v is None or (isinstance(v, float) and v != v) else v
    return out


def _get_spark():
    try:
        return spark  # noqa: F821 — Databricks global
    except NameError:
        from pyspark.sql import SparkSession
        return SparkSession.builder.getOrCreate()


# ─────────────────────────────────────────────────────────────────────────────
# LLM core — pass ① propose, pass ② verify
# ─────────────────────────────────────────────────────────────────────────────

def build_catalog_block(catalog):
    """Catalog reference, sent once as a cached system block.

    SORTED BY PART NUMBER: the block is the cache key and part of the prompt, so a
    query-order-dependent block both misses the prompt cache and makes the same
    concept resolvable differently run to run. item_short_name is included because
    the long name is heavily abbreviated ("DF COCONT MILK (CURRY)(M)") and the two
    together disambiguate more items than either alone.

    TODO(scale): ~2.5k active rows is fine as one cached block. If it grows, prefer
    an EMBEDDING-based candidate shortlist over a lexical/brand-token prefilter — a
    string-overlap shortlist can both drop the true match (different wording) and
    keep a false one (e.g. "banh mi XYZ" token-matching "XYZ Noodles"), with no
    broader catalog left for the model to notice the mismatch.
    """
    rows = sorted(catalog, key=lambda c: str(c.get("prtnum") or ""))
    lines = [
        "\t".join([
            str(c.get("prtnum")),
            str(c.get("item_name") or ""),
            str(c.get("item_short_name") or ""),
            str(c.get("item_family") or ""),
        ])
        for c in rows
    ]
    return ("CATALOG (prtnum<TAB>item_name<TAB>item_short_name<TAB>item_family):\n"
            + "\n".join(lines))


def _render_snippets(snippets):
    lines = ["Representative mentions:"]
    if not snippets:
        lines.append("  (no snippets found — you have NO evidence of what this token means)")
    for s in snippets:
        lines.append(f"  - {s['text'] or '(no caption text)'}")
        extra = []
        if s["dishes"]:
            extra.append("dishes=" + ", ".join(s["dishes"][:6]))
        if s.get("products"):
            extra.append("products=" + ", ".join(s["products"][:6]))
        if s["ingredients"]:
            extra.append("ingredients=" + ", ".join(s["ingredients"][:8]))
        if s["brands"]:
            extra.append("brands=" + ", ".join(s["brands"][:6]))
        if extra:
            lines.append("      (" + "; ".join(extra) + ")")
    return lines


def build_user_prompt(concept, snippets):
    lines = [
        f"Concept (raw): {concept['concept_norm']}",
        f"Seen as: {_class_hint(concept)}   Mentions: {concept.get('mention_count')}",
        "",
    ]
    return "\n".join(lines + _render_snippets(snippets))


def build_verify_prompt(concept, snippets, proposal, candidates):
    lines = [
        f"Concept (raw): {concept['concept_norm']}",
        f"Proposed label: {proposal.get('canonical_label')}",
        f"Proposed result_type: {proposal.get('result_type')}",
        "",
        "Candidates (part number, AUTHORITATIVE catalog name, short name, family, "
        "how it was proposed):",
    ]
    for c in candidates:
        lines.append(
            f"  - {c['prtnum']}\t{c['item_name']}\t{c['item_short_name']}\t"
            f"{c['item_family']}\t[{c['role']}]"
        )
    lines.append("")
    return "\n".join(lines + _render_snippets(snippets))


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


def _call_json(client, instructions, catalog_block, user_prompt, max_tokens,
               is_valid, stage, label):
    """One prompted-JSON call with our own retry on unusable output. Shared by
    both passes so the retry/parse/diagnostic behaviour can't diverge."""
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            system = [{"type": "text", "text": instructions}]
            if catalog_block:
                system.append({"type": "text", "text": catalog_block,
                               "cache_control": {"type": "ephemeral"}})
            resp = _create_message(
                client, model=MODEL, max_tokens=max_tokens, system=system,
                messages=[{"role": "user", "content": user_prompt}],
            )
            # usage is accumulated per stage and reported ONCE at the end of the run.
            # It used to print per call, and ~100 such lines per run is what let a
            # truncated grouping reply hide in plain sight (2026-08-19).
            u = resp.usage
            t = _USAGE[stage]
            t["calls"] += 1
            t["input"] += u.input_tokens or 0
            t["cache_read"] += getattr(u, "cache_read_input_tokens", 0) or 0
            t["output"] += u.output_tokens or 0

            # A reply cut off at max_tokens is not invalid JSON by accident — it is our
            # ceiling being too low, and retrying reproduces it exactly. Say which it is,
            # and stop wasting the retry.
            if getattr(resp, "stop_reason", None) == "max_tokens":
                t["truncated"] += 1
                print(f"  WARN {stage} {label!r}: reply hit the {max_tokens}-token "
                      f"ceiling and was cut off — raise it; retrying would truncate "
                      f"identically", file=sys.stderr)
                return None

            data = extract_json(next((b.text for b in resp.content if b.type == "text"), ""))
            if data and is_valid(data):
                return data
        except Exception as e:
            if attempt == MAX_ATTEMPTS:
                print(f"  WARN {stage} {label!r}: {e}", file=sys.stderr)
    return None


def report_usage():
    """One line per stage at the end of a run: calls, tokens, and whether prompt
    caching actually took effect. Confirmed 2026-08-19 that the Databricks serving
    proxy DOES honour cache_control — the 81.5k-token catalog block reads from cache
    on every call after the first."""
    if not _USAGE:
        return
    print("usage by stage (cache_read > 0 means the catalog block is being cached):")
    for stage, t in _USAGE.items():
        print(f"  {stage:<9} {t['calls']:>4} calls  in={t['input']:>8}  "
              f"cached_in={t['cache_read']:>9}  out={t['output']:>7}"
              + (f"  TRUNCATED={t['truncated']}" if t["truncated"] else ""))


def _proposal_ok(d):
    return _REQUIRED_KEYS.issubset(d) and d.get("result_type") in _VALID_RESULT


def _verdict_ok(d):
    return (isinstance(d.get("verdicts"), list)
            and d.get("result_type") in _VALID_RESULT
            and all(isinstance(v, dict) and "prtnum" in v and "keep" in v
                    for v in d["verdicts"]))


def propose_one(client, catalog_block, concept, snippets):
    return _call_json(client, INSTRUCTIONS, catalog_block,
                      build_user_prompt(concept, snippets), MAX_TOKENS,
                      _proposal_ok, "propose", concept["concept_norm"])


def group_concepts(client, concepts, brand_keys=frozenset()):
    """ONE call over the whole board: which concepts are the same thing?

    Why this exists: every concept is otherwise resolved in ISOLATION, so when the model
    sees "matcha" it has no idea "matcha powder" is also on this week's board. Both
    answers come back correct and separately labelled, and the board shows one trend
    twice with its mentions split (observed 2026-08-19: ranks 1 and 4, both SKU 68250).
    Nothing downstream can spot that, because there is nothing wrong with either row.

    NOT grouped by matched_prtnum, though that would have caught this case: two genuinely
    different trends can share a SKU — a generic category and a branded product often
    resolve to the same item — so SKU equality over-merges. Sameness has to be judged
    explicitly, which is what this call does.

    Returns {concept_norm: (primary_concept_norm, group_label)}. Fails SAFE: on any
    validation problem every concept becomes its own group, i.e. today's behaviour."""
    ungrouped = {c["concept_norm"]: (c["concept_norm"], None) for c in concepts}
    if len(concepts) < 2:
        return ungrouped

    lines = ["Concepts on this week's board:"]
    for c in sorted(concepts, key=lambda c: -c.get("mention_count", 0)):
        lines.append(f"  [{_class_hint(c)}] {c['concept_norm']}   "
                     f"({c.get('mention_count')} mentions)")
    # Sized from the input, not a flat cap. The first version asked for every concept
    # echoed back under MAX_TOKENS * 2 = 1400, and 40 concepts did not fit: the reply was
    # truncated mid-JSON, BOTH attempts hit exactly the cap, and the whole grouping was
    # discarded (observed 2026-08-19 — nothing merged, and the log looked like a model
    # that had simply found no duplicates). The prompt now asks only for the groups that
    # actually merge, so this ceiling is generous rather than tight; it still scales with
    # the board, because a silent truncation is indistinguishable from an honest "no
    # duplicates" in the output.
    data = _call_json(client, GROUP_INSTRUCTIONS, None, "\n".join(lines),
                      MAX_TOKENS + 100 * len(concepts),
                      lambda d: isinstance(d.get("groups"), list),
                      "group", f"{len(concepts)} concepts")
    if data is None:
        return ungrouped

    # VALIDATE before trusting: a bad grouping fuses real trends, so anything that
    # doesn't account for exactly the input set is discarded wholesale.
    by_norm = {c["concept_norm"]: c for c in concepts}
    # every concept starts alone; the reply only has to describe the merges
    mapping, seen = dict(ungrouped), set()
    for g in data["groups"]:
        members = [str(m) for m in (g.get("members") or [])]
        primary = str(g.get("primary") or "")
        label = str(g.get("label") or "").strip() or None
        if not members or primary not in members:
            print("  WARN grouping: primary not in its own members — ignoring the "
                  "whole grouping", file=sys.stderr)
            return ungrouped
        classes = set()
        for m in members:
            if m not in by_norm or m in seen:
                print(f"  WARN grouping: {m!r} unknown or repeated — ignoring the "
                      f"whole grouping", file=sys.stderr)
                return ungrouped
            seen.add(m)
            classes.add(_class_hint(by_norm[m]))
        if len(classes) > 1:
            print(f"  WARN grouping: group {primary!r} mixes boards {classes} — "
                  f"ignoring the whole grouping", file=sys.stderr)
            return ungrouped
        if len(members) > 1:
            for m in members:
                mapping[m] = (primary, label)

    # ── REFUTE THE MERGES ────────────────────────────────────────────────────────
    # First real run merged 3 wrong out of 4 — a brand into its category (มาม่า into
    # "instant noodles"), and two varieties into their base — while missing the one pair
    # the prompt used as its worked example. Prompt rules alone did not hold, and the
    # error is asymmetric: a wrong merge buries the more specific signal, which is the
    # opposite of what the item board is for. So proposed merges now face the same
    # propose-then-refute treatment that fixed the SKU matching, defaulting to refusal.
    proposed = [(m, p) for m, (p, _) in mapping.items() if p != m]
    if proposed:
        keep = review_merges(client, proposed)
        for member, primary in proposed:
            # DETERMINISTIC GUARD, applied after the review and overriding it. If exactly
            # one side is a string the enrichment called a brand, this is a brand being
            # folded into a category — the worst of the v6 mistakes (มาม่า into "instant
            # noodles"), and the part of the judgment that needs no model at all. Note no
            # string rule can replace the review generally: a superstring test blocks
            # ก๋วยเตี๋ยวเรือ and น้ำพริกแซ่บ correctly but ALSO blocks matcha powder, which must
            # merge, and misses มาม่า entirely. Blocking costs at most a visible duplicate.
            if (member in brand_keys) != (primary in brand_keys):
                brand, other = ((member, primary) if member in brand_keys
                                else (primary, member))
                print(f"  merge BLOCKED: {brand!r} is a known brand and {other!r} is "
                      f"not — a brand is never the same thing as a category")
                mapping[member] = (member, None)
                continue
            if (primary, member) not in keep:
                mapping[member] = (member, None)     # refused -> stands alone

    merged = {p for p, _ in mapping.values() if sum(1 for v in mapping.values()
                                                    if v[0] == p) > 1}
    for p in sorted(merged):
        members = sorted(m for m, v in mapping.items() if v[0] == p and m != p)
        print(f"  grouped: {p!r} absorbs {members}")
    print(f"  grouping: {len(concepts)} concepts -> "
          f"{len(set(p for p, _ in mapping.values()))} groups")
    return mapping


def review_merges(client, proposed):
    """Second opinion on each proposed merge. Returns the set of (primary, member) pairs
    that survive; anything not explicitly accepted is discarded, so a failed or
    unparseable call refuses every merge and the board simply stays unmerged."""
    lines = ["Proposed merges — for each, are these the SAME thing?", ""]
    for member, primary in sorted(proposed):
        lines.append(f'  primary: "{primary}"   member: "{member}"')
    data = _call_json(client, MERGE_REVIEW_INSTRUCTIONS, None, "\n".join(lines),
                      MAX_TOKENS + 120 * len(proposed),
                      lambda d: isinstance(d.get("verdicts"), list),
                      "merge-review", f"{len(proposed)} merges")
    if data is None:
        print(f"  merge review failed — refusing all {len(proposed)} proposed merges",
              file=sys.stderr)
        return set()

    asked = {(p, m) for m, p in proposed}
    keep = set()
    for v in data["verdicts"]:
        if not isinstance(v, dict):
            continue
        pair = (str(v.get("primary")), str(v.get("member")))
        if pair not in asked:
            continue
        if v.get("same"):
            keep.add(pair)
        else:
            print(f"  merge REFUSED: {pair[1]!r} is not {pair[0]!r} — "
                  f"{str(v.get('reason') or '')[:100]}")
    return keep


def build_recovery_prompt(concept, snippets, ruled_out):
    """Same context as the proposer, plus what has already been ruled out and why, so
    the second look spends its effort somewhere new."""
    lines = [f"Concept (raw): {concept['concept_norm']}",
             f"Seen as: {_class_hint(concept)}   Mentions: {concept.get('mention_count')}",
             ""]
    if ruled_out:
        lines.append("ALREADY RULED OUT by review — do not offer these again:")
        for prtnum, reason in ruled_out:
            lines.append(f"  - {prtnum}: {reason or '(no reason given)'}")
    else:
        lines.append("The first pass proposed nothing at all.")
    lines.append("")
    return "\n".join(lines + _render_snippets(snippets))


def recover_one(client, catalog_block, concept, snippets, ruled_out):
    """Second look at the catalog for a concept that came back 'none'.

    Exists because the verify pass can only SUBTRACT. Withholding the catalog from the
    reviewer is deliberate — it keeps it judging the candidates in front of it instead
    of shopping for replacements — but the cost is that a proposer MISS is
    unrecoverable, and for a 'none' result that miss becomes a false "nothing like this
    in stock" on the board. That is the most expensive error this table can make: it
    sends someone to source a product we already sell (observed with mayonnaise,
    2026-08-19).

    Whatever this returns is still put through verify_one, so recall improves without
    loosening precision one bit."""
    return _call_json(client, RECOVERY_INSTRUCTIONS, catalog_block,
                      build_recovery_prompt(concept, snippets, ruled_out),
                      MAX_TOKENS, _proposal_ok, "recover", concept["concept_norm"])


def verify_one(client, concept, snippets, proposal, candidates):
    """Pass ②. Deliberately does NOT get the catalog block: the candidates are
    already rendered with their authoritative names, and withholding the other
    2.5k rows keeps the reviewer from shopping for a replacement item instead of
    judging the ones in front of it."""
    return _call_json(client, VERIFY_INSTRUCTIONS, None,
                      build_verify_prompt(concept, snippets, proposal, candidates),
                      VERIFY_MAX_TOKENS, _verdict_ok, "verify", concept["concept_norm"])


def _norm_name(s):
    return re.sub(r"[^A-Z0-9]+", " ", str(s or "").upper()).strip()


def _name_agrees(claimed, authoritative):
    """Did the proposer's own name for this SKU match what the SKU actually is?
    A disagreement means its prtnum and its intent came apart (the arrays are 1:1
    by convention only), so the pair is suspect — recorded, and left for pass ② to
    judge against the AUTHORITATIVE name."""
    a, b = _norm_name(claimed), _norm_name(authoritative)
    if not a or not b:
        return True          # nothing claimed -> nothing to contradict
    return a == b or a in b or b in a


def build_candidates(proposal, catalog_by_prtnum):
    """Proposer output -> verifiable candidate list. Drops hallucinated part
    numbers (not in the ACTIVE catalog) and de-dupes, preserving the proposer's
    order; returns the name-mismatch diagnostic alongside."""
    candidates, mismatches, seen = [], [], set()
    matched = str(proposal["matched_prtnum"]) if proposal.get("matched_prtnum") else None
    claimed_names = proposal.get("recommended_item_names") or []

    def _add(prtnum, role, claimed=None):
        item = catalog_by_prtnum.get(prtnum)
        if item is None or prtnum in seen:
            return
        seen.add(prtnum)
        if claimed is not None and not _name_agrees(claimed, item.get("item_name")):
            mismatches.append(prtnum)
        candidates.append({
            "prtnum": prtnum,
            "item_name": str(item.get("item_name") or ""),
            "item_short_name": str(item.get("item_short_name") or ""),
            "item_family": str(item.get("item_family") or ""),
            "role": role,
        })

    if matched:
        _add(matched, "matched")
    for i, p in enumerate(proposal.get("recommended_prtnums") or []):
        _add(str(p), "recommended",
             claimed_names[i] if i < len(claimed_names) else None)
    return candidates, mismatches, matched


def _clamp(x, lo=0.0, hi=1.0):
    try:
        return max(lo, min(hi, float(x)))
    except (TypeError, ValueError):
        return lo


def reconcile(proposal, verdict, candidates, matched):
    """Apply pass ②'s verdicts. result_type is DERIVED from what actually
    survived rather than taken on trust — a reviewer that rejects every item but
    still answers "basket" must not leave an empty basket labelled as one."""
    keep, reject = {}, []
    for v in verdict["verdicts"]:
        p = str(v.get("prtnum"))
        if v.get("keep"):
            keep[p] = str(v.get("reason") or "")[:200]
        else:
            reject.append((p, str(v.get("reason") or "")[:200]))

    matched_ok = bool(matched) and matched in keep
    kept = [c["prtnum"] for c in candidates
            if c["role"] == "recommended" and c["prtnum"] in keep][:MAX_RECOMMENDATIONS]

    if matched_ok:
        result_type = "carried"
        kept = []                       # a carried match stands on its own
    elif kept:
        for source in (verdict.get("result_type"), proposal.get("result_type")):
            if source in ("substitute", "basket"):
                result_type = source
                break
        else:
            result_type = "basket"
    else:
        result_type = "none"

    by_prtnum = {c["prtnum"]: c for c in candidates}
    return {
        "result_type": result_type,
        "matched_prtnum": matched if matched_ok else None,
        "recommended_prtnums": kept,
        "recommended_item_names": [by_prtnum[p]["item_name"] for p in kept],
        "recommended_reasons": [keep[p] for p in kept],
        "rejected_prtnums": [p for p, _ in reject],
        "rejected_reasons": [r for _, r in reject],
        "confidence": _clamp(verdict.get("confidence")) if result_type != "none" else 0.0,
        "canonical_label": (str(verdict.get("canonical_label") or "").strip()
                            or str(proposal.get("canonical_label") or "").strip()),
    }


def resolve_one(client, catalog_block, catalog_by_prtnum, concept, snippets, verify=True):
    """Full two-pass resolution for one concept. Returns a record dict, or None
    to leave the concept unresolved for a later run (fail closed — an unverified
    match must never reach the board)."""
    label = concept["concept_norm"]
    proposal = propose_one(client, catalog_block, concept, snippets)
    if proposal is None:
        return None

    candidates, mismatches, matched = build_candidates(proposal, catalog_by_prtnum)
    base = {
        "concept_norm": str(label),
        "canonical_label": str(proposal.get("canonical_label") or label),
        "concept_type": str(proposal["concept_type"]),
        "name_mismatch_prtnums": mismatches,
        "proposer_confidence": _clamp(proposal.get("match_confidence")),
        "snippet_count": len(snippets),
    }

    if not verify:
        # --no-verify is a smoke-test path only; model_version is tagged so these
        # rows can never be mistaken for verified ones (and are re-resolved once
        # the script runs normally again).
        base.update({
            "result_type": proposal["result_type"] if candidates or proposal["result_type"] == "none" else "none",
            "matched_prtnum": matched,
            "recommended_prtnums": [c["prtnum"] for c in candidates if c["role"] == "recommended"],
            "recommended_item_names": [c["item_name"] for c in candidates if c["role"] == "recommended"],
            "recommended_reasons": [], "rejected_prtnums": [], "rejected_reasons": [],
            "match_confidence": _clamp(proposal.get("match_confidence")),
        })
        return base

    if candidates:
        verdict = verify_one(client, concept, snippets, proposal, candidates)
        if verdict is None:
            print(f"  SKIP {label!r}: verification failed — left unresolved for the "
                  f"next run (no unverified match written)", file=sys.stderr)
            return None
        applied = reconcile(proposal, verdict, candidates, matched)
    else:
        # the proposer offered nothing at all — nothing to review
        applied = {
            "result_type": "none", "matched_prtnum": None,
            "recommended_prtnums": [], "recommended_item_names": [],
            "recommended_reasons": [], "rejected_prtnums": [], "rejected_reasons": [],
            "confidence": 0.0, "canonical_label": base["canonical_label"],
        }

    # ── SECOND LOOK ──────────────────────────────────────────────────────────────
    # A 'none' is the one answer worth paying to double-check: it reaches the board as
    # "we don't carry this and have nothing like it" and sends someone to source a
    # product we may already sell. The verify pass cannot rescue it — by design it only
    # subtracts — so give the catalog to a fresh call, tell it what was already ruled
    # out, and put anything it finds through the SAME verifier. Recall improves;
    # precision is untouched, because nothing skips review.
    if applied["result_type"] == "none":
        ruled_out = list(zip(applied["rejected_prtnums"], applied["rejected_reasons"]))
        second = recover_one(client, catalog_block, concept, snippets, ruled_out)
        if second is not None:
            already = {p for p, _ in ruled_out}
            cands2, mismatch2, matched2 = build_candidates(second, catalog_by_prtnum)
            # a verdict already stands on those part numbers; don't re-litigate it
            cands2 = [c for c in cands2 if c["prtnum"] not in already]
            if matched2 in already:
                matched2 = None
            if cands2:
                verdict2 = verify_one(client, concept, snippets, second, cands2)
                if verdict2 is not None:
                    applied2 = reconcile(second, verdict2, cands2, matched2)
                    if applied2["result_type"] != "none":
                        n_found = (1 if applied2["matched_prtnum"] else 0) \
                                  + len(applied2["recommended_prtnums"])
                        print(f"  RECOVERED {label!r}: second look found "
                              f"{applied2['result_type']} ({n_found} item(s)) where the "
                              f"first pass said none")
                        # keep the first pass's rejections in the audit trail alongside
                        applied2["rejected_prtnums"] = (applied["rejected_prtnums"]
                                                        + applied2["rejected_prtnums"])
                        applied2["rejected_reasons"] = (applied["rejected_reasons"]
                                                        + applied2["rejected_reasons"])
                        applied = applied2
                        base["name_mismatch_prtnums"] = mismatches + mismatch2

    base.update({
        "canonical_label": applied["canonical_label"] or base["canonical_label"],
        "result_type": applied["result_type"],
        "matched_prtnum": applied["matched_prtnum"],
        "recommended_prtnums": applied["recommended_prtnums"],
        "recommended_item_names": applied["recommended_item_names"],
        "recommended_reasons": applied["recommended_reasons"],
        "rejected_prtnums": applied["rejected_prtnums"],
        "rejected_reasons": applied["rejected_reasons"],
        "match_confidence": applied["confidence"],
    })
    return base


def resolve_batch(client, catalog_block, catalog_by_prtnum, concepts,
                  snippets_by_concept, concurrency, verify=True):
    out = {}
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = {
            pool.submit(resolve_one, client, catalog_block, catalog_by_prtnum, c,
                        snippets_by_concept.get(c["concept_norm"], []), verify): c
            for c in concepts
        }
        for fut in futures:
            c = futures[fut]
            data = fut.result()
            if data is not None:
                out[c["concept_norm"]] = data
    return out


def finalize_records(by_concept, resolved_at, model_version):
    """Stamp run metadata on each row."""
    records = []
    for r in by_concept.values():
        r = dict(r)
        r["resolved_at"] = resolved_at
        r["model_version"] = model_version
        records.append(_coerce_record(r))
    return records




# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def main(backend="local", limit=None, top_n=TOP_N, dry_run=False,
         concurrency=CONCURRENCY, duckdb_path=LOCAL_DUCKDB_PATH, verify=True):
    model_version = _CURRENT_VERSION if verify else f"{_CURRENT_VERSION}-noverify"
    concepts, snippets, catalog, existing, brand_keys = read_all(
        backend, top_n, duckdb_path, model_version)
    if limit:
        concepts = concepts[:limit]
    print(f"{len(existing)} already resolved; {len(concepts)} new top-{top_n} "
          f"concepts to resolve; catalog has {len(catalog)} items")

    # The snippet lookup is load-bearing (see SQL PARITY above) and used to fail
    # silently. Every ranked concept exists BECAUSE some in-window mention named
    # that dish, so zero snippets means the keys have drifted apart again — say so
    # loudly rather than resolving a bare token.
    starved = [c["concept_norm"] for c in concepts
               if not snippets.get(c["concept_norm"])]
    if starved:
        print(f"WARN {len(starved)}/{len(concepts)} concepts matched NO in-window "
              f"snippets — these resolve blind and will be returned as 'none'. "
              f"Run scripts/check_fold_consistency.py: {starved[:5]}", file=sys.stderr)

    if not concepts:
        print("nothing to do.")
        return

    catalog_block = build_catalog_block(catalog)
    catalog_by_prtnum = {str(c["prtnum"]): c for c in catalog}

    if dry_run:
        print(f"[dry-run] would resolve {len(concepts)} concepts with {MODEL} "
              f"({'propose + verify, then a second look at any none'
                 if verify else 'propose only'}).")
        print(f"catalog block: {len(catalog_block)} chars. First prompt:\n")
        c0 = concepts[0]
        print(build_user_prompt(c0, snippets.get(c0["concept_norm"], [])))
        return

    client = get_client(backend)
    resolved_at = datetime.now(timezone.utc)

    # ── GROUP FIRST ──────────────────────────────────────────────────────────────
    # One call over the whole board, so "matcha" and "matcha powder" are known to be
    # one trend BEFORE anything is resolved. Then each group is resolved ONCE and the
    # answer is written for every member, which also cuts calls.
    groups = group_concepts(client, concepts, brand_keys) if verify else              {c["concept_norm"]: (c["concept_norm"], None) for c in concepts}
    primaries = {}
    for c in concepts:
        primary, _ = groups[c["concept_norm"]]
        primaries.setdefault(primary, dict(c))
        if primary != c["concept_norm"]:
            # the group's volume is the sum — it is one trend, and the prompt shows
            # this number as context
            primaries[primary]["mention_count"] = (
                (primaries[primary].get("mention_count") or 0)
                + (c.get("mention_count") or 0))
    to_resolve = list(primaries.values())
    total = len(to_resolve)

    all_records = {}
    for start in range(0, total, BATCH_SIZE):
        chunk = to_resolve[start:start + BATCH_SIZE]
        res = resolve_batch(client, catalog_block, catalog_by_prtnum, chunk,
                            snippets, concurrency, verify)
        recs = finalize_records(res, resolved_at, model_version)
        all_records.update({r["concept_norm"]: r for r in recs})
        print(f"  batch {start // BATCH_SIZE + 1}: resolved {len(res)}/{len(chunk)} "
              f"(cumulative {len(all_records)}/{total})")

    # every member of a resolved group gets the group's answer, tagged with the
    # primary it came from so the SQL side can merge the mentions too
    to_write = []
    for c in concepts:
        norm = c["concept_norm"]
        primary, label = groups[norm]
        answer = all_records.get(primary)
        if answer is None:          # its group failed to resolve; retry next run
            continue
        row = dict(answer)
        row["concept_norm"] = norm
        row["group_primary"] = primary
        row["group_label"] = label
        to_write.append(_coerce_record(row))
    write_resolution(backend, to_write)

    written = len(all_records)
    report_usage()
    failed = total - written
    kinds = defaultdict(int)
    for r in all_records.values():
        kinds[r["result_type"]] += 1
    print(f"DONE. wrote {len(to_write)} rows for {written} resolved group(s)"
          + f": {dict(kinds)}"
          + (f"; {failed} unresolved (propose or verify failed) — re-run to "
             f"backfill (incremental)" if failed else ""))


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
    p.add_argument("--no-verify", dest="verify", action="store_false",
                   help="SMOKE TEST ONLY: skip the verification pass. Rows are "
                        "written under a '-noverify' model_version so they can't "
                        "pass as verified.")
    args = p.parse_args()
    try:
        sys.stdout.reconfigure(encoding="utf-8")  # concepts carry Thai/Vietnamese text
    except Exception:
        pass
    main(backend=args.backend, limit=args.limit, top_n=args.top_n,
         dry_run=args.dry_run, concurrency=args.concurrency,
         duckdb_path=args.duckdb, verify=args.verify)
