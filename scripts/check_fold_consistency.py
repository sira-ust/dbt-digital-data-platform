"""Guard against the SQL and Python copies of the concept-key normalisation
drifting apart again.

concept_norm is built in SQL as fold_concept(strip_parenthetical_gloss(dish))
(models/intermediate/int_social_concept_trends.sql). scripts/resolve_trending_
concepts.py has to rebuild the SAME key in Python to look up which mention
snippets belong to a trending concept, so BOTH steps are duplicated there and
BOTH are checked here:

  1. the 67-character Vietnamese translate() table (macros/fold_concept.sql vs
     _FOLD_FROM/_FOLD_TO). The original Python version used a from-scratch
     Unicode NFKD/combining-mark strip instead of copying the macro, and silently
     stripped Thai tone marks the macro leaves untouched (both from commit
     5b6fe2f) — undetected until this check was written.
  2. the trailing-gloss regex (macros/strip_parenthetical_gloss.sql vs
     _GLOSS_PATTERN). The Python side did not strip the gloss AT ALL, so every
     concept whose dish strings carried an LLM-appended "(...)" gloss matched no
     snippets and was resolved from a bare token — the cause of the wrong
     recommendation baskets found 2026-08-18.

Run by hand or in CI:

    python scripts/check_fold_consistency.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FOLD_MACRO_PATH = ROOT / "macros" / "fold_concept.sql"
GLOSS_MACRO_PATH = ROOT / "macros" / "strip_parenthetical_gloss.sql"

_TRANSLATE_RE = re.compile(
    r"translate\(\s*lower\(trim\([^)]*\)\),\s*'([^']*)',\s*'([^']*)'",
    re.DOTALL,
)

# the default__ (DuckDB) spelling — the databricks__/spark__ variants are the same
# pattern with doubled backslashes for their string-literal parser, which is why
# the macro dispatches at all. Python's re takes the single-backslash form.
_GLOSS_MACRO_RE = re.compile(
    r"default__strip_parenthetical_gloss.*?regexp_replace\(trim\([^)]*\),\s*'([^']*)'",
    re.DOTALL,
)

# (input, expected key) — deglossing runs BEFORE folding, and a concept that is
# ENTIRELY parenthetical falls back to the original text instead of vanishing
# (same fallback as the CASE in int_social_concept_trends).
_KEY_CASES = [
    ("Bánh Khọt", "banh khot"),
    ("bánh khọt (vietnamese crispy pancake)", "banh khot"),
    ("ขนมโตเกียว (tokyo pastry/snack)", "ขนมโตเกียว"),
    ("ข้าวมัน", "ข้าวมัน"),
    ("Som  Tam  (green papaya salad)", "som tam"),
    ("(tokyo pastry)", "(tokyo pastry)"),
    ("banh mi (chicken) extra (spicy)", "banh mi (chicken) extra"),
]


def macro_translate_args() -> tuple[str, str]:
    text = FOLD_MACRO_PATH.read_text(encoding="utf-8")
    m = _TRANSLATE_RE.search(text)
    if not m:
        raise SystemExit(f"could not find translate(...) args in {FOLD_MACRO_PATH}")
    return m.group(1), m.group(2)


def macro_gloss_pattern() -> str:
    text = GLOSS_MACRO_PATH.read_text(encoding="utf-8")
    m = _GLOSS_MACRO_RE.search(text)
    if not m:
        raise SystemExit(f"could not find the default__ regex in {GLOSS_MACRO_PATH}")
    return m.group(1)


def check_fold_table(rtc) -> int:
    sql_from, sql_to = macro_translate_args()
    script_from, script_to = rtc._FOLD_FROM, rtc._FOLD_TO
    if (script_from, script_to) == (sql_from, sql_to):
        print(f"OK — fold table matches {FOLD_MACRO_PATH.name} ({len(sql_from)} chars).")
        return 0
    print(
        "MISMATCH: resolve_trending_concepts.py's _FOLD_FROM/_FOLD_TO has drifted "
        "from macros/fold_concept.sql's translate() table. Copy the macro's "
        "arguments into the script verbatim.",
        file=sys.stderr,
    )
    print(f"  macro  FROM ({len(sql_from)} chars): {sql_from}", file=sys.stderr)
    print(f"  script FROM ({len(script_from)} chars): {script_from}", file=sys.stderr)
    print(f"  macro  TO   ({len(sql_to)} chars): {sql_to}", file=sys.stderr)
    print(f"  script TO   ({len(script_to)} chars): {script_to}", file=sys.stderr)
    return 1


def check_gloss_pattern(rtc) -> int:
    sql_pattern = macro_gloss_pattern()
    if rtc._GLOSS_PATTERN == sql_pattern:
        print(f"OK — gloss regex matches {GLOSS_MACRO_PATH.name} ({sql_pattern!r}).")
        return 0
    print(
        "MISMATCH: resolve_trending_concepts.py's _GLOSS_PATTERN has drifted from "
        "macros/strip_parenthetical_gloss.sql's default__ regex. The snippet lookup "
        "keys will stop matching concept_norm and concepts will be resolved with no "
        "mention context.",
        file=sys.stderr,
    )
    print(f"  macro  ({sql_pattern!r}) vs script ({rtc._GLOSS_PATTERN!r})", file=sys.stderr)
    return 1


def check_key_cases(rtc) -> int:
    bad = [(raw, want, rtc._concept_key(raw))
           for raw, want in _KEY_CASES if rtc._concept_key(raw) != want]
    if not bad:
        print(f"OK — {len(_KEY_CASES)} concept-key cases produce the expected key.")
        return 0
    print("MISMATCH: _concept_key() no longer reproduces concept_norm:", file=sys.stderr)
    for raw, want, got in bad:
        print(f"  {raw!r}: expected {want!r}, got {got!r}", file=sys.stderr)
    return 1


def main() -> int:
    sys.path.insert(0, str(ROOT / "scripts"))
    import resolve_trending_concepts as rtc

    try:
        sys.stdout.reconfigure(encoding="utf-8")  # the key cases carry Thai text
    except Exception:
        pass

    return max(check_fold_table(rtc), check_gloss_pattern(rtc), check_key_cases(rtc))


if __name__ == "__main__":
    raise SystemExit(main())
