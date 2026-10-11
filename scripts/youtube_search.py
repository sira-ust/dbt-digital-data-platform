"""Search YouTube for promo items social listening did not find (step 4).

For every BRANDED promo item of the month with no Social Listening match (no row
in int_promo_social_matches), run the item's reviewed search_queries through the
YouTube Data API v3:

    search.list   top N videos per query            100 quota units each
    videos.list   title, description, tags, views,   1 unit per 50 videos
                  likes, publish date, duration

Each video then gets the SAME Exact rule as a social post (promo_common.ItemTerms
over title + description + tags) and, when the keywords say exact, the same AI
judge. int_promo_scraped_matches keeps the top 1-3 judged-Exact videos by views.

THE TABLE IS THE CACHE. Every video returned is stored with its evidence and
verdict, keyed by (promo_month, item_no). An item that already has rows for the
month is not searched again — reruns cost no quota. --refresh re-searches.
Free quota is 10,000 units a day; at the default 3 queries an item costs ~303.

Shorts: the API has no Shorts flag. youtube.com/shorts/<id> answers 200 for a
Short and redirects for a regular video, so that is checked for kept videos only.

API key: local runs read YOUTUBE_API_KEY from the environment or .env; on
Databricks it comes from secret scope ust-social, key youtube-api-key (the job's
run-as identity needs READ on that scope).

    python scripts/youtube_search.py --dry-run      # list items + queries, no API calls
    python scripts/youtube_search.py                # search, verify, judge
    python scripts/youtube_search.py --backend databricks
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path.cwd() / "scripts"))
try:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
except NameError:
    pass

from promo_common import (  # noqa: E402
    INTERMEDIATE_SCHEMA, JUDGE_PROMPT_VERSION, LANDING, ItemTerms, append_records, dbt_var,
    ensure_landing, find_project_root, get_llm_client, judge_majority, landing_path, match_text, query,
    read_local_parquet, split_terms,
)

API = "https://www.googleapis.com/youtube/v3"
SECRET_SCOPE, SECRET_KEY = "ust-social", "youtube-api-key"
UNITS_SEARCH, UNITS_VIDEOS = 100, 1


# ─────────────────────────────────────────────────────────────────────────────
# API key + HTTP
# ─────────────────────────────────────────────────────────────────────────────

def api_key(backend: str) -> str:
    if backend == "databricks":
        from databricks.sdk import WorkspaceClient
        value = WorkspaceClient().secrets.get_secret(scope=SECRET_SCOPE, key=SECRET_KEY).value
        return base64.b64decode(value).decode("utf-8").strip()
    if os.environ.get("YOUTUBE_API_KEY"):
        return os.environ["YOUTUBE_API_KEY"].strip()
    env = find_project_root() / ".env"
    if env.exists():
        for line in env.read_text(encoding="utf-8").splitlines():
            if line.strip().startswith("YOUTUBE_API_KEY="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise SystemExit("No YouTube API key: set YOUTUBE_API_KEY or add it to .env")


def _get(path: str, params: dict) -> dict:
    url = f"{API}/{path}?{urllib.parse.urlencode(params)}"
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        key = params.get("key", "")
        raise RuntimeError(f"YouTube API {e.code}: {body[:300].replace(key, '<key>')}") from None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def is_short(video_id: str) -> bool:
    """True when youtube.com/shorts/<id> serves the video instead of redirecting."""
    opener = urllib.request.build_opener(_NoRedirect)
    req = urllib.request.Request(f"https://www.youtube.com/shorts/{video_id}", method="HEAD",
                                 headers={"User-Agent": "Mozilla/5.0"})
    try:
        with opener.open(req, timeout=15) as r:
            return r.status == 200
    except urllib.error.HTTPError:
        return False          # 3xx lands here with redirects disabled
    except Exception:
        return False


# ─────────────────────────────────────────────────────────────────────────────
# Inputs
# ─────────────────────────────────────────────────────────────────────────────

ITEM_FIELDS = ["promo_month", "item_no", "promo_description", "item_full_description", "brand",
               "product", "flavor_variant", "pack_format", "brand_terms", "product_terms",
               "flavor_terms", "negative_terms", "search_queries"]


def items_to_search(backend: str, promo_month: str | None) -> tuple[str, list[dict]]:
    sch = INTERMEDIATE_SCHEMA if backend == "databricks" else "ust_intermediate"
    if not promo_month:
        promo_month = str(query(backend, f"select max(promo_month) as m from {sch}.int_promo_items_enriched")[0]["m"])[:10]
    rows = query(backend, f"""
        select {', '.join('i.' + f for f in ITEM_FIELDS)}
        from {sch}.int_promo_items_enriched as i
        where i.promo_month = date '{promo_month}'
          and i.is_branded
          and i.search_queries is not null
          and not exists (
              select 1 from {sch}.int_promo_social_matches as s
              where s.promo_month = i.promo_month and s.item_no = i.item_no
          )
    """)
    seen, out = set(), []
    for r in rows:
        if r["item_no"] not in seen:
            seen.add(r["item_no"])
            out.append(r)
    _attach_siblings(backend, sch, promo_month, out)
    return promo_month, out


def _attach_siblings(backend, sch, promo_month, items):
    """The same brand's other promo items, for the judge (see match_promo_social)."""
    rows = query(backend, f"select distinct item_no, brand, product, flavor_variant, promo_description "
                          f"from {sch}.int_promo_items_enriched where promo_month = date '{promo_month}' "
                          f"and brand is not null")
    for it in items:
        b = (it.get("brand") or "").strip().casefold()
        it["_siblings"] = sorted({
            " ".join(x for x in (o["brand"], o["product"], o["flavor_variant"]) if x)
            + f" ({o['promo_description']})"
            for o in rows if o["item_no"] != it["item_no"] and (o["brand"] or "").strip().casefold() == b
        })


def already_searched(backend: str, promo_month: str) -> set[str]:
    spec = LANDING["youtube_videos"]
    if backend == "databricks":
        rows = query(backend, f"select distinct item_no from {spec['dbx']} where promo_month = '{promo_month}'")
    else:
        rows = [r for r in read_local_parquet(landing_path("youtube_videos"))
                if str(r.get("promo_month"))[:10] == promo_month]
    return {str(r["item_no"]) for r in rows}


# ─────────────────────────────────────────────────────────────────────────────
# Search one item
# ─────────────────────────────────────────────────────────────────────────────

def search_item(key: str, item: dict, max_queries: int, per_query: int) -> tuple[list[dict], int]:
    """Every distinct video the item's queries return, with stats. -> (videos, quota units)."""
    units, order, first_query = 0, [], {}
    for q in split_terms(item["search_queries"])[:max_queries]:
        res = _get("search", {"part": "snippet", "type": "video", "maxResults": per_query, "q": q, "key": key})
        units += UNITS_SEARCH
        for rank, hit in enumerate(res.get("items", []), start=1):
            vid = hit.get("id", {}).get("videoId")
            if vid and vid not in first_query:
                first_query[vid] = (q, rank)
                order.append(vid)
    videos = []
    for i in range(0, len(order), 50):
        res = _get("videos", {"part": "snippet,statistics,contentDetails",
                              "id": ",".join(order[i:i + 50]), "key": key})
        units += UNITS_VIDEOS
        for v in res.get("items", []):
            sn, st = v.get("snippet", {}), v.get("statistics", {})
            q, rank = first_query[v["id"]]
            videos.append({
                "video_id": v["id"], "search_query": q, "query_rank": rank,
                "title": sn.get("title"), "description": sn.get("description"),
                "tags": "|".join(sn.get("tags") or []) or None,
                "channel_title": sn.get("channelTitle"), "channel_id": sn.get("channelId"),
                "published_at": sn.get("publishedAt"),
                "view_count": st.get("viewCount"), "like_count": st.get("likeCount"),
                "comment_count": st.get("commentCount"),
                "duration": v.get("contentDetails", {}).get("duration"),
            })
    return videos, units


def verify(client, model: str, item: dict, videos: list[dict], concurrency: int, votes: int = 3) -> list[dict]:
    """Keyword evidence for every video; the judge for keyword-exact ones only
    (a scraped row must be Exact, so a Close video is not worth a call)."""
    terms = ItemTerms(item["brand_terms"], item["product_terms"], item["flavor_terms"], item["negative_terms"])
    now = datetime.now(timezone.utc).replace(tzinfo=None).isoformat(sep=" ", timespec="seconds")
    todo = []
    for v in videos:
        text = match_text(v["title"], v["description"], (v["tags"] or "").replace("|", " "))
        ev = terms.classify(text)
        v.update(promo_month=item["promo_month"], item_no=item["item_no"], match_text=text,
                 keyword_level=ev["keyword_level"], brand_hit=ev["brand_hit"],
                 product_hit=ev["product_hit"], flavor_hit=ev["flavor_hit"], searched_at=now,
                 judge_version=JUDGE_PROMPT_VERSION)
        if ev["keyword_level"] == "exact":
            todo.append((v, ev))

    def one(pair):
        v, ev = pair
        post = {"channel": "YouTube video",
                "text": f"TITLE: {v['title']}\nTAGS: {v['tags'] or '-'}\nDESCRIPTION: {(v['description'] or '')[:2000]}"}
        try:
            res = judge_majority(client, model, item, post, ev, votes)
        except Exception as e:
            print(f"    ! judge failed for {v['video_id']}: {str(e)[:100]}")
            res = None
        if res:
            v.update(verdict=res["verdict"], judge_votes=res["votes"],
                     matched_content_item=res["matched_content_item"],
                     reason=res["reason"], judge_model=model)
            if res["verdict"] == "exact":
                v["is_short"] = "true" if is_short(v["video_id"]) else "false"

    if todo and client is not None:
        with ThreadPoolExecutor(max_workers=concurrency) as pool:
            list(pool.map(one, todo))
    return videos


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--backend", choices=["local", "databricks"], default="local")
    ap.add_argument("--promo-month", help="YYYY-MM-01 (default: the latest loaded month)")
    ap.add_argument("--refresh", action="store_true", help="search again even if cached for the month")
    ap.add_argument("--dry-run", action="store_true", help="show items and queries; no API calls")
    ap.add_argument("--max-queries", type=int, default=int(dbt_var("promo_youtube_max_queries_per_item", 3)))
    ap.add_argument("--results", type=int, default=int(dbt_var("promo_youtube_results_per_query", 25)))
    ap.add_argument("--model", default=dbt_var("promo_judge_model", "databricks-claude-sonnet-5"))
    ap.add_argument("--votes", type=int, default=int(dbt_var("promo_judge_votes", 3)))
    ap.add_argument("--concurrency", type=int, default=8)
    args = ap.parse_args(argv)

    ensure_landing(args.backend)
    month, items = items_to_search(args.backend, args.promo_month)
    cached = set() if args.refresh else already_searched(args.backend, month)
    todo = [it for it in items if it["item_no"] not in cached]
    print(f"{month}: {len(items)} branded item(s) with no social listening match; "
          f"{len(items) - len(todo)} already searched this month; {len(todo)} to search "
          f"(~{len(todo) * (args.max_queries * UNITS_SEARCH + 1):,} quota units)")
    for it in todo:
        print(f"  {it['item_no']} {it['promo_description'][:32]:32s} {split_terms(it['search_queries'])[:args.max_queries]}")
    if args.dry_run or not todo:
        return

    key = api_key(args.backend)
    client = get_llm_client(args.backend)
    spec = LANDING["youtube_videos"]
    total_units = 0
    for it in todo:
        try:
            videos, units = search_item(key, it, args.max_queries, args.results)
        except RuntimeError as e:
            print(f"  ! {it['item_no']}: {e} — stopping; searched items are saved")
            break
        total_units += units
        videos = verify(client, args.model, it, videos, args.concurrency, args.votes)
        # an item with zero results still gets a marker row, so the cache knows it was searched
        rows = videos or [{"promo_month": month, "item_no": it["item_no"], "video_id": None,
                           "searched_at": datetime.now(timezone.utc).replace(tzinfo=None).isoformat(sep=" ", timespec="seconds")}]
        append_records(args.backend, rows, landing_path("youtube_videos"), spec["dbx"], spec["columns"])
        kept = sum(1 for v in videos if v.get("verdict") == "exact")
        print(f"  {it['item_no']} {it['promo_description'][:32]:32s} {len(videos):3d} videos, "
              f"{sum(1 for v in videos if v.get('keyword_level') == 'exact'):2d} keyword-exact, {kept} judged exact")
    print(f"done — {total_units:,} quota units used")


if __name__ == "__main__":
    main()
