"""Regenerate seed glossary docs blocks from the CSVs in seeds/.

Produces one {% docs %} block per seed in models/docs/_seed_glossaries.md,
embedded into the seed descriptions in seeds/_seeds.yml via {{ doc(...) }}.

Run after any change to a seed, then `dbt docs generate`:

    python scripts/generate_event_glossary.py
"""

import csv
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SEEDS = ROOT / "seeds"
OUT = ROOT / "models" / "docs" / "_seed_glossaries.md"

AUTOGEN_NOTE = (
    "> Auto-generated from `seeds/{name}.csv` by\n"
    "> `scripts/generate_event_glossary.py` — do not edit by hand;\n"
    "> re-run the script when the seed changes.\n"
)


def read_seed(name: str) -> list[dict]:
    with (SEEDS / f"{name}.csv").open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def md_table(rows: list[dict], headers: dict[str, str], code_cols: set[str] = frozenset()) -> list[str]:
    lines = [
        "| " + " | ".join(headers.values()) + " |",
        "|" + "---|" * len(headers),
    ]
    for r in rows:
        cells = []
        for col in headers:
            v = (r.get(col) or "—").replace("|", "\\|")
            cells.append(f"`{v}`" if col in code_cols and v != "—" else v)
        lines.append("| " + " | ".join(cells) + " |")
    return lines


def event_code_glossary() -> list[str]:
    rows = read_seed("seed_event_codes")
    by_l1: dict[str, list[dict]] = {}
    for row in rows:
        by_l1.setdefault(row["description_code"][:2], []).append(row)

    lines = [
        "{% docs event_code_glossary %}",
        "Complete event dictionary from API documentation Section 5",
        "(SystemEventLog_API_Documentation_0327, v1.0 March 2026).",
        "",
        "Grain: one row per 8-digit `description_code`",
        "(digits 1-2 = L1 Category, 3-4 = L2 Sub-category, 5-6 = L3 Action,",
        "7-8 = L4 Result: 01=Success, 02=Fail, 00=N/A).",
        "",
        "`payload_format` legend: none | kv (key:value CSV) | positional_order",
        "(order metadata CSV) | positional (other multi-field CSV) | duration",
        "(`Time:s`) | sku | title | bare_value | fail_marker.",
        "",
        AUTOGEN_NOTE.format(name="seed_event_codes"),
    ]
    headers = {
        "description_code": "Code",
        "function_name": "Function",
        "payload_format": "Payload",
        "has_geo": "Geo",
        "is_system_event": "System",
        "event_type": "Type",
        "log_level": "Level",
        "platforms": "Platforms",
    }
    for l1 in sorted(by_l1):
        group = sorted(by_l1[l1], key=lambda r: r["description_code"])
        lines.append(f"\n### L1 = {l1} — {group[0]['l1_category_name']} ({len(group)} events)\n")
        lines.extend(md_table(group, headers, code_cols={"description_code"}))
        lines.append("")
    lines.append("{% enddocs %}")
    print(f"event_code_glossary: {len(rows)} events in {len(by_l1)} L1 categories")
    return lines


def app_sources_glossary() -> list[str]:
    rows = read_seed("seed_app_sources")
    lines = [
        "{% docs app_sources_glossary %}",
        "All 9 app source codes from API documentation Section 2.3.",
        "Naming convention: App Name - Platform (I=iOS, A=Android);",
        "single-platform apps omit the suffix.",
        "",
        AUTOGEN_NOTE.format(name="seed_app_sources"),
        "",
    ]
    headers = {
        "source_code": "Source code",
        "app_name": "App",
        "app_full_name": "Full name",
        "user_type": "User type",
        "platform": "Platform",
    }
    lines.extend(md_table(sorted(rows, key=lambda r: r["source_code"]), headers, code_cols={"source_code"}))
    lines.append("{% enddocs %}")
    print(f"app_sources_glossary: {len(rows)} sources")
    return lines


def categories_glossary() -> list[str]:
    rows = read_seed("seed_categories")
    real = [r for r in rows if len(r["category_id"]) < 4]
    virtual = [r for r in rows if len(r["category_id"]) >= 4]
    lines = [
        "{% docs categories_glossary %}",
        "Complete catalog category id -> name map from API documentation §8.4",
        "(18 categories). 4-digit repeated ids (1111, 4444, ...) are virtual",
        "app sections, not real product categories.",
        "",
        AUTOGEN_NOTE.format(name="seed_categories"),
        "",
        "### Product categories",
        "",
    ]
    headers = {"category_id": "Id", "category_name": "Name"}
    lines.extend(md_table(sorted(real, key=lambda r: int(r["category_id"])), headers, code_cols={"category_id"}))
    lines.extend(["", "### Virtual sections", ""])
    lines.extend(md_table(sorted(virtual, key=lambda r: int(r["category_id"])), headers, code_cols={"category_id"}))
    lines.append("{% enddocs %}")
    print(f"categories_glossary: {len(real)} product categories, {len(virtual)} virtual sections")
    return lines


def main() -> None:
    blocks = [event_code_glossary(), app_sources_glossary(), categories_glossary()]
    content = "\n".join("\n".join(b) for b in blocks) + "\n"
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(content, encoding="utf-8")
    print(f"Wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
