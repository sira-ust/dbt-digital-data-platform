"""Regenerate the jdawms column glossary from the WMS data dictionary seed.

Reads  seeds/seed_jdawms_data_dictionary.csv  (SME-verified definitions) and
rewrites:

  models/docs/_jdawms_glossary.md            -- {% docs %} blocks for shared defs
  models/staging/jdawms/_jdawms__sources.yml -- column descriptions
  models/staging/jdawms/_jdawms__models.yml  -- adds a description for every
                                                 column not already documented
                                                 there, reusing the exact text
                                                 just written to sources.yml

Why models.yml too: dbt's `persist_docs` (which pushes descriptions into
Databricks as real column comments) only ever reads from a model's OWN yaml
-- it never inherits from the source, even for a byte-identical 1:1 passthrough
column. Previously models.yml only listed tested columns, so only those had
comments in Unity Catalog; everything else showed blank in Catalog Explorer
despite being fully documented in sources.yml. This step closes that gap by
copying each column's already-resolved description (dictionary text or a
{{ doc(...) }} ref, whichever sources.yml ended up with) into models.yml too,
appended after any existing tested-column entries. Existing entries are never
touched, so hand-tuned descriptions (e.g. dlytrn_id's) are preserved as-is.

Rules
-----
* Definition text = "<lngdsc> — <column_comment>" (em dash), except:
    - comment empty            -> keep the YAML's existing description (reported)
    - lngdsc empty             -> comment only
    - comment ~= lngdsc        -> lngdsc only (avoid "Row ID — Row ID")
    - comment startswith lngdsc-> comment only (avoid double label)
* Dedup by MEANING, not column name: a (column_name, text) pair used by 2+
  tables becomes a shared {% docs %} block; single-use text stays inline.
    - largest same-text group for a column   -> jdawms__<col>
    - other 2+ table variants                -> jdawms__<col>__<first_table>
* Columns not in the dictionary (loaddate, _rescued_data, ...) are left
  untouched; any doc blocks they still reference are carried over from the
  previous glossary so all {{ doc() }} refs keep resolving.

Run from the repo root:  python scripts/generate_jdawms_glossary.py
"""

import csv
import re
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SEED = ROOT / "seeds" / "seed_jdawms_data_dictionary.csv"
GLOSSARY = ROOT / "models" / "docs" / "_jdawms_glossary.md"
SOURCES = ROOT / "models" / "staging" / "jdawms" / "_jdawms__sources.yml"
MODELS = ROOT / "models" / "staging" / "jdawms" / "_jdawms__models.yml"
REVIEW = ROOT / "models" / "docs" / "_jdawms_glossary_review.md"

GLOSSARY_HEADER = """\
{# ---------------------------------------------------------------------------
   Shared column definitions for the jdawms (JDA/Blue Yonder WMS) source.

   AUTO-GENERATED from seeds/seed_jdawms_data_dictionary.csv by
   scripts/generate_jdawms_glossary.py -- do not edit by hand. To change a
   definition, edit the seed (or the WMS data dictionary it came from) and
   re-run the script.

   Definitions are deduplicated by MEANING: a (column, text) pair used by 2+
   tables becomes one block here; table-specific meanings stay inline in
   _jdawms__sources.yml. Variant blocks are suffixed with a table name, e.g.
   jdawms__ins_dt__pckwrk_dtl.

   Blocks under "pipeline / carried-over" are not in the data dictionary
   (ingestion columns etc.) and are preserved from the previous glossary.
--------------------------------------------------------------------------- #}
"""


def norm(s: str) -> str:
    """Whitespace-collapsed, lowercased, no trailing punctuation -- for comparisons."""
    return re.sub(r"\s+", " ", s or "").strip().rstrip(".").lower()


def clean(s: str) -> str:
    """Whitespace-collapsed display text."""
    return re.sub(r"\s+", " ", s or "").strip()


def build_text(lngdsc: str, comment: str) -> str | None:
    """Compose the definition text; None means 'no dictionary coverage'."""
    lngdsc, comment = clean(lngdsc), clean(comment)
    if not comment:
        return None  # empty comment = no coverage; keep existing description
    if not lngdsc or norm(comment).startswith(norm(lngdsc)):
        text = comment
    elif norm(comment) == norm(lngdsc):
        text = lngdsc
    else:
        text = f"{lngdsc} — {comment}"
    if text[-1] not in ".!?":
        text += "."
    return text


def backfill_models_yml(sources_out_lines: list[str]) -> int:
    """Add a description for every column not yet documented in models.yml,
    reusing the exact rendered text/doc-ref just written to sources.yml.
    Never touches existing entries. Returns the number of entries added.
    """
    # (table, column) -> rendered RHS of "description: ..." from sources.yml,
    # and the natural (source) column order per table.
    src_desc: dict[tuple[str, str], str] = {}
    src_order: dict[str, list[str]] = defaultdict(list)
    table = column = None
    for line in sources_out_lines:
        m = re.match(r"^      - name: (\S+)\s*$", line)
        if m:
            table, column = m.group(1), None
        m = re.match(r"^          - name: (\S+)\s*$", line)
        if m and table:
            column = m.group(1)
            src_order[table].append(column)
        m = re.match(r"^            description: (.*)$", line)
        if m and table and column:
            src_desc[(table, column)] = m.group(1)

    lines = MODELS.read_text(encoding="utf-8").splitlines()
    models_idx = next(i for i, l in enumerate(lines) if l.strip() == "models:")
    header, body = lines[: models_idx + 1], lines[models_idx + 1 :]

    starts = [i for i, l in enumerate(body) if re.match(r"^  - name: stg_jdawms__", l)]
    n_added = 0
    new_body: list[str] = []
    for i, start in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else len(body)
        block = body[start:end]
        while block and block[-1].strip() == "":
            block = block[:-1]

        table = re.match(r"^  - name: stg_jdawms__(\S+)\s*$", block[0]).group(1)
        existing = {
            re.match(r"^      - name: (\S+)\s*$", l).group(1)
            for l in block
            if re.match(r"^      - name: (\S+)\s*$", l)
        }
        missing = [c for c in src_order.get(table, []) if c not in existing]

        insert: list[str] = []
        if missing and not any(l.strip() == "columns:" for l in block):
            insert.append("    columns:")
        for col in missing:
            insert.append(f"      - name: {col}")
            insert.append(f"        description: {src_desc[(table, col)]}")
            n_added += 1

        new_body.extend(block + insert + [""])

    while new_body and new_body[-1] == "":
        new_body.pop()
    MODELS.write_text("\n".join(header + new_body) + "\n", encoding="utf-8")
    return n_added


def main() -> None:
    # ---- 1. dictionary -> per-(table, column) definition text -------------
    defs: dict[tuple[str, str], str] = {}
    no_comment: list[tuple[str, str]] = []
    with open(SEED, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            key = (row["table_name"], row["column_name"])
            text = build_text(row["lngdsc"], row["column_comment"])
            if text is None:
                no_comment.append(key)
            else:
                defs[key] = text

    # ---- 2. group identical (column, text) across tables; assign slugs ----
    # Only count tables whose replica YAML actually has the column — a pair
    # shared in the dictionary but landed by one table must stay inline.
    yaml_text = SOURCES.read_text(encoding="utf-8")
    yaml_keys: set[tuple[str, str]] = set()
    table = column = None
    for line in yaml_text.splitlines():
        m = re.match(r"^      - name: (\S+)\s*$", line)
        if m:
            table, column = m.group(1), None
        m = re.match(r"^          - name: (\S+)\s*$", line)
        if m:
            column = m.group(1)
        if re.match(r"^            description: ", line) and table and column:
            yaml_keys.add((table, column))

    groups: dict[tuple[str, str], list[str]] = defaultdict(list)  # (col, text) -> tables
    for (table, col), text in defs.items():
        if (table, col) in yaml_keys:
            groups[(col, text)].append(table)

    slug_for: dict[tuple[str, str], str] = {}  # (col, text) -> slug (shared only)
    by_col: dict[str, list[tuple[str, list[str]]]] = defaultdict(list)
    for (col, text), tables in groups.items():
        by_col[col].append((text, sorted(tables)))
    for col, variants in by_col.items():
        shared = [v for v in variants if len(v[1]) >= 2]
        if not shared:
            continue
        # largest group wins the plain slug; ties broken by first table name
        shared.sort(key=lambda v: (-len(v[1]), v[1][0]))
        for i, (text, tables) in enumerate(shared):
            slug = f"jdawms__{col}" if i == 0 else f"jdawms__{col}__{tables[0]}"
            slug_for[(col, text)] = slug

    # ---- 3. load old glossary (to carry over non-dictionary blocks) -------
    old_blocks = dict(
        re.findall(
            r"\{%\s*docs\s+(\S+)\s*%\}(.*?)\{%\s*enddocs\s*%\}",
            GLOSSARY.read_text(encoding="utf-8"),
            re.DOTALL,
        )
    )

    # ---- 4. rewrite column descriptions in the sources YAML ---------------
    lines = yaml_text.splitlines()
    table = column = None
    out: list[str] = []
    untouched: list[tuple[str, str]] = []  # YAML columns with no dict coverage
    n_inline = n_ref = 0
    for line in lines:
        m = re.match(r"^      - name: (\S+)\s*$", line)  # table (6-space indent)
        if m:
            table, column = m.group(1), None
        m = re.match(r"^          - name: (\S+)\s*$", line)  # column (10-space)
        if m:
            column = m.group(1)
        m = re.match(r"^            description: ", line)  # column desc (12-space)
        if m and table and column:
            key = (table, column)
            if key in defs:
                text = defs[key]
                slug = slug_for.get((column, text))
                if slug:
                    out.append(f'            description: "{{{{ doc(\'{slug}\') }}}}"')
                    n_ref += 1
                else:
                    escaped = text.replace('"', '\\"')
                    out.append(f'            description: "{escaped}"')
                    n_inline += 1
            else:
                out.append(line)  # no coverage -> keep as-is
                untouched.append(key)
            continue
        out.append(line)
    SOURCES.write_text("\n".join(out) + "\n", encoding="utf-8")

    # ---- 4b. backfill models.yml so persist_docs covers every column ------
    n_backfilled = backfill_models_yml(out)

    # ---- 5. glossary = dict-derived shared blocks + carried-over refs -----
    new_yaml = "\n".join(out)
    referenced = set(re.findall(r"doc\('(jdawms__[a-z0-9_]+)'\)", new_yaml))
    dict_slugs = set(slug_for.values())
    carried = sorted(referenced - dict_slugs)
    missing = [s for s in carried if s not in old_blocks]
    if missing:
        raise SystemExit(f"refs with no block to carry over: {missing}")

    parts = [GLOSSARY_HEADER]
    for (col, text), slug in sorted(slug_for.items(), key=lambda kv: kv[1]):
        tables = ", ".join(sorted(groups[(col, text)]))
        parts.append(f"{{# {tables} #}}")
        parts.append(f"{{% docs {slug} %}}{text}{{% enddocs %}}\n")
    parts.append("{# ---- pipeline / carried-over (not in the data dictionary) ---- #}\n")
    for slug in carried:
        parts.append(f"{{% docs {slug} %}}{old_blocks[slug].strip()}{{% enddocs %}}\n")
    GLOSSARY.write_text("\n".join(parts), encoding="utf-8")

    # ---- 6. report (stdout + models/docs/_jdawms_glossary_review.md) ------
    print(f"dictionary definitions: {len(defs)} across {len({t for t, _ in defs})} tables")
    print(f"shared blocks: {len(dict_slugs)} (+{len(carried)} carried over: {', '.join(carried)})")
    print(f"YAML descriptions written: {n_ref} doc refs + {n_inline} inline")
    print(f"models.yml backfilled: {n_backfilled} new column entries (for persist_docs / Databricks comments)")

    # columns whose dictionary text differs between tables (shared OR inline)
    multi = {col: sorted(vs, key=lambda v: (-len(v[1]), v[1][0]))
             for col, vs in by_col.items() if len(vs) > 1}
    pipeline_cols = {"loaddate", "_rescued_data"}
    unexpected = [(t, c) for t, c in untouched
                  if c not in pipeline_cols and (t, c) not in set(no_comment)]

    r = [
        "# jdawms glossary — human-review queue",
        "",
        "AUTO-GENERATED by scripts/generate_jdawms_glossary.py alongside",
        "_jdawms_glossary.md — do not edit by hand (checkboxes reset on rerun;",
        "record resolutions in the seed / WMS dictionary instead).",
        "",
        "Resolve items by fixing seeds/seed_jdawms_data_dictionary.csv (and the",
        "upstream WMS dictionary) and re-running the generator.",
        "",
        f"## 1. Columns whose meaning differs between tables ({len(multi)})",
        "",
        "For each: confirm the difference is real (keep) or dictionary phrasing",
        "noise (align the wording in the seed so the texts merge).",
        "",
    ]
    for col in sorted(multi):
        r.append(f"### `{col}`")
        for text, tables in multi[col]:
            slug = slug_for.get((col, text))
            kind = f"`{slug}`" if slug else "inline"
            r.append(f"- [ ] {kind} ({', '.join(tables)}): {text}")
        r.append("")
    r += [
        f"## 2. Dictionary rows with no column_comment ({len(no_comment)})",
        "",
        "Prior AI-inferred text was kept. Needs SME wording in the dictionary.",
        "Rows marked (not landed) are absent from the replica YAML — low priority.",
        "",
    ]
    for t, c in sorted(no_comment):
        landed = "" if (t, c) in yaml_keys else " *(not landed)*"
        r.append(f"- [ ] `{t}.{c}`{landed}")
    r += [
        "",
        f"## 3. Landed columns missing from the dictionary ({len(unexpected)})",
        "",
        "Pipeline columns (loaddate, _rescued_data) are excluded — anything",
        "listed here means the dictionary is stale relative to the replica.",
        "",
    ]
    r += [f"- [ ] `{t}.{c}`" for t, c in sorted(unexpected)] or ["(none)"]
    r.append("")
    REVIEW.write_text("\n".join(r), encoding="utf-8")

    print(f"review queue -> {REVIEW.relative_to(ROOT)}")
    print(f"  1. multi-meaning columns: {len(multi)} ({', '.join(sorted(multi))})")
    print(f"  2. empty-comment rows:    {len(no_comment)}")
    print(f"  3. missing from dict:     {len(unexpected)}")


if __name__ == "__main__":
    main()
