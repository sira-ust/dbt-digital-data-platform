# AI / LLM Integration Guide

How to give an LLM (Claude, Genie, or any model) useful access to the UST
Digital Platform data in Databricks — written 2026-06-12 after the initial
Databricks migration. Reference for when we build the "chat with the data"
capability.

## TL;DR

- No LLM has automatic access to anything — every option below works by
  supplying our **dbt metadata as context** and/or giving the model
  **tools** to explore the warehouse itself.
- Our dbt investment is the enabler: YAML descriptions, seeds, tests, and
  lineage already exist in machine-readable form. Every column description
  written in dbt does triple duty: dbt docs (humans), Databricks column
  comments via `persist_docs` (Catalog Explorer + Genie), and LLM context.
- Start with **Genie** (free, already in the workspace), graduate to a
  **custom Claude-powered app** when people outside Databricks need to ask
  questions.

---

## Why dbt pays off here (vs traditional ETL)

Traditional ETL buries meaning in procedural code and people's heads — an
LLM sees `description_code varchar(8)` and has to guess. dbt forced that
knowledge into machine-readable artifacts as a *byproduct* of building the
pipeline:

| Knowledge | Where it lives | Machine-readable? |
|---|---|---|
| What each column means | `models/**/_*__models.yml` descriptions | Yes — manifest.json + Databricks comments |
| Business vocabulary | `seeds/seed_event_codes.csv` etc. | Yes — queryable dim tables |
| Table relationships | `ref()` graph | Yes — manifest.json + UC lineage |
| Data invariants | 56 dbt tests | Yes — manifest.json |
| Transformation logic | Declarative SQL models | Yes — readable SQL |

Caveat: dbt gives knowledge a home, it doesn't generate it. Empty
descriptions = no payoff. Keep documenting `_reporting__models.yml` first —
that's what AI tools read most.

## Context sources in this repo

1. **`dbt docs generate` artifacts** — `target/manifest.json` (models,
   descriptions, columns, lineage, tests) and `target/catalog.json`
   (live warehouse types/stats). Regenerate with
   `dbt docs generate --target databricks`.
2. **Databricks column/table comments** — `persist_docs: relation/columns`
   is enabled in `dbt_project.yml`, so YAML descriptions are already
   written into Unity Catalog. `DESCRIBE TABLE` / `information_schema`
   returns them. This is why Genie works well here.
3. **Dimension views** — `ust_dimensions.dim_event_codes`,
   `dim_app_sources`, `dim_categories` give any tool the code→name
   mappings (e.g. `01040100` = Location-Success).

## Options compared

| Option | Who can use it | Cost | Status |
|---|---|---|---|
| **Databricks Genie** | Databricks account holders only | Warehouse compute only (cents) | Available now — Genie Spaces in sidebar |
| **Power BI Copilot** | Anyone with report access | Requires Premium/Fabric license | Check org license first |
| **Claude Code (this repo)** | Developer (me) | Claude subscription + warehouse | Works today — ask questions in a session |
| **Custom Claude app** | Anyone we give access (web/Teams) | API tokens (~1-2¢/question) + warehouse | Not built — design below |

Notes:
- Databricks' built-in MCP endpoint (`/api/2.0/mcp/v1`) exposes *platform
  tools* (run SQL you wrote, browse catalog), not NL-to-SQL — it is not the
  "ask questions in English" solution. Needs an `all-apis` scoped token.
- The `databricks-mcp` pip package is a helper library for building agents
  *inside* Databricks, not an MCP server for Claude.

---

## Custom app architecture (when we build it)

User asks a question → Claude plans → calls tools → answers in English.

### Two context patterns (use both)

**Pattern A — docs in a cached system prompt.** Extract schema +
descriptions from `manifest.json` (~10-20K tokens) into the system prompt
with a `cache_control` breakpoint. After the first request, repeat
questions read the docs at ~10% of input price (5-min cache TTL).

**Pattern B — tools for live exploration.** The model decides the sequence
itself (multi-hop): schema → relationships → sample data → SQL → recover
from errors. Not pre-programmed; the model chains calls based on tool
descriptions and feeds SQL errors back into its next attempt. See
"How multi-hop agentic tool use works" below.

### How multi-hop agentic tool use works

The key concept: **you don't program the sequence — the model decides it.**
Multi-hop behavior (check schema → understand relationships → peek at
sample data → write query → recover from errors) is what current frontier
LLMs are trained to do; it's called *agentic tool use*.

You give the model a set of tools, each with a name, description, and
parameters. When a question comes in, the model reasons about what it
needs and chains calls on its own. Worked example with our data:

> *"Which sales team had the most failed orders per active rep last month?"*
>
> 1. `list_tables` → sees `mart_team_performance` and `fct_orders_submitted`
> 2. `describe_table` on both → notices it must relate `sales_code`
>    across them
> 3. `sample_rows` on `fct_orders_submitted` → checks what `is_failure`
>    values actually look like
> 4. Writes and runs the SQL via `run_sql`
> 5. If Databricks returns an error, reads the error text and fixes the
>    query itself

**Real example from the build session (2026-06-12):** investigating why
`mart_team_activity_daily` showed only one event category, the model
queried the mart, then tried `stg_mysql__system_events` for
`l1_category_name`, got `UNRESOLVED_COLUMN` back from Databricks, read the
error, realized the category lives in the enrichment layer, and re-queried
`int_events_enriched` instead. Nobody scripted that recovery — the error
message came back as a tool result and the model adjusted course.

### What makes it work well vs poorly

1. **Tool descriptions that say *when* to use them** — "Call `sample_rows`
   before writing SQL against a column whose format you're unsure of"
   measurably improves behavior over bare what-it-does descriptions.
2. **Good metadata in tool results** — when `describe_table` returns our
   dbt column comments ("8-digit hierarchical code, leading zeros
   matter"), the model writes correct SQL on the first try far more
   often. This is the dbt payoff again, one level deeper.
3. **Errors fed back, not swallowed** — return the SQL error text as the
   tool result and the model self-corrects; hide it and the loop dies.
4. **A capable model** — multi-hop planning quality is a major
   differentiator between frontier models and cheaper ones.

Honest caveats:

- Each hop costs tokens and a warehouse query — a complex question may
  take 5–10 tool calls (still cents, but not one).
- The model can occasionally take an inefficient path; a system-prompt
  nudge like *"check table schemas before writing SQL rather than
  guessing column names"* helps.
- Genie does a narrower version of this loop internally (schema lookup +
  SQL generation) but its toolset can't be extended. With the Claude API
  the toolset is ours — we can add `get_lineage`,
  `check_data_freshness`, or even `create_chart`.

### Recommended toolset

| Tool | Backing | Description guidance |
|---|---|---|
| `list_tables` | `information_schema.tables` + comments | "List tables with their business descriptions" |
| `describe_table` | `DESCRIBE TABLE` (returns persisted dbt docs) | "Get columns, types, and meanings — call before writing SQL" |
| `get_lineage` | parse `manifest.json` | "Show which tables feed into a table" |
| `sample_rows` | `SELECT * LIMIT 5` | "Call when unsure about a column's format" |
| `run_sql` | databricks-sql-connector, **read-only token** | "Execute read-only SQL; errors are returned for you to fix" |

Tool descriptions should say *when* to call, not just what it does —
prescriptive trigger conditions measurably improve tool selection.

### Sketch (Python, Anthropic SDK)

```python
import anthropic
from anthropic import beta_tool
from databricks import sql as dbsql

client = anthropic.Anthropic()  # ANTHROPIC_API_KEY in env

@beta_tool
def run_sql(query: str) -> str:
    """Execute a read-only SQL query against ust_databricks and return
    the results. If the query errors, the error text is returned —
    read it and fix your SQL.

    Args:
        query: Databricks SQL. SELECT only.
    """
    conn = dbsql.connect(
        server_hostname="adb-7405618436278207.7.azuredatabricks.net",
        http_path="/sql/1.0/warehouses/e165fed86011619a",
        access_token=READONLY_TOKEN,  # scoped to ust_reporting/ust_dimensions
    )
    try:
        cur = conn.cursor()
        cur.execute(query)
        cols = [d[0] for d in cur.description]
        rows = cur.fetchmany(200)
        return str([dict(zip(cols, r)) for r in rows])
    except Exception as e:
        return f"SQL ERROR: {e}"
    finally:
        conn.close()

SYSTEM = open("docs/schema_context.md").read()  # generated from manifest.json

runner = client.beta.messages.tool_runner(
    model="claude-opus-4-8",
    max_tokens=16000,
    thinking={"type": "adaptive"},
    system=[{"type": "text", "text": SYSTEM,
             "cache_control": {"type": "ephemeral"}}],
    tools=[run_sql],  # + describe_table, get_lineage, sample_rows
    messages=[{"role": "user", "content": user_question}],
)
for message in runner:
    ...  # last message is the answer
```

(`tool_runner` handles the agentic loop — executes tools, feeds results
back, stops when the model is done.)

---

## Cost model

- **Databricks side**: each tool call = one warehouse query, billed per
  second of warehouse uptime. Multi-hop question ≈ 3-10 queries ≈ cents.
  Keep warehouse auto-stop at 5 min.
- **Claude API side**: ~1-2¢ per question at this scale with prompt
  caching; grows with hops and result sizes. Use the cached system prompt
  to avoid re-paying for docs context per question.

## Security checklist (before exposing to others)

- [ ] Create a **dedicated read-only Databricks token** granted SELECT on
      `ust_reporting` + `ust_dimensions` only — not staging/raw, not the
      dbt token.
- [ ] `run_sql` should reject non-SELECT statements as defense in depth.
- [ ] Staging/raw tables contain identifiers (usernames, customer numbers,
      device names, lat/lon). Marts are aggregated — keep the AI surface
      on marts unless there's a reason not to.
- [ ] Conversation content (incl. query results) flows through the LLM
      provider. Check the org's Anthropic plan data-retention terms before
      pointing at sensitive data.
- [ ] Log questions + generated SQL for audit.

## Sequence to build

1. Genie Space over `ust_reporting` + `ust_dimensions` (now, free).
2. Generate `docs/schema_context.md` from `manifest.json` (script).
3. Prototype the tool-using CLI above; validate answer quality on the
   sample data.
4. Wrap in a small web app or Teams bot once real MySQL data lands and
   the read-only token + grants exist.
