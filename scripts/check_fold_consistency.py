"""Guard against macros/fold_concept.sql and resolve_trending_concepts.py's
_FOLD_FROM/_FOLD_TO drifting apart again.

They are two independent hardcoded copies of the same 67-character Vietnamese
translate() table — one in SQL, one in Python. The previous Python version
used a from-scratch Unicode NFKD/combining-mark strip instead of copying the
macro, and silently stripped Thai tone marks the macro leaves untouched
(macros/fold_concept.sql / scripts/resolve_trending_concepts.py, both from
commit 5b6fe2f) — undetected until this check was written. Run by hand or in CI:

    python scripts/check_fold_consistency.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MACRO_PATH = ROOT / "macros" / "fold_concept.sql"

_TRANSLATE_RE = re.compile(
    r"translate\(\s*lower\(trim\([^)]*\)\),\s*'([^']*)',\s*'([^']*)'",
    re.DOTALL,
)


def macro_translate_args() -> tuple[str, str]:
    text = MACRO_PATH.read_text(encoding="utf-8")
    m = _TRANSLATE_RE.search(text)
    if not m:
        raise SystemExit(f"could not find translate(...) args in {MACRO_PATH}")
    return m.group(1), m.group(2)


def main() -> int:
    sys.path.insert(0, str(ROOT / "scripts"))
    import resolve_trending_concepts as rtc

    sql_from, sql_to = macro_translate_args()
    script_from, script_to = rtc._FOLD_FROM, rtc._FOLD_TO

    if (script_from, script_to) == (sql_from, sql_to):
        print(f"OK — fold table matches macros/fold_concept.sql ({len(sql_from)} chars).")
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


if __name__ == "__main__":
    raise SystemExit(main())
