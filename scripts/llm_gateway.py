"""Claude through Databricks Unity AI Gateway — the one place the LLM scripts build
their client.

Every script that calls Claude (enrich_mentions, canonicalize_concepts,
resolve_trending_concepts and the promo scripts via promo_common) gets its client
here, so the gateway route and the sign-in live in exactly one place. Before
2026-11 each script carried its own copy pointed at the legacy workspace serving
route (/serving-endpoints/anthropic, models named databricks-claude-*), which
Databricks retires once "Enforce Unity AI Gateway" is switched on.

The anthropic SDK is pointed at https://<host>/ai-gateway/anthropic with a
Databricks bearer token (api_key is unused). Models are Unity Catalog model
services, named system.ai.claude-<model>.

Sign-in:
  --backend databricks  the job's run-as identity (ambient, no PAT, no secret).
                        It needs EXECUTE on the model service (account users have
                        it by default) plus USE CATALOG / USE SCHEMA on system.ai.
  --backend local       DATABRICKS_SERVING_TOKEN if set — a PAT with the
                        `ai-gateway` scope — otherwise a browser sign-in (cached
                        after the first time). The everyday DATABRICKS_TOKEN PAT is
                        deliberately NOT used: it is scoped to SQL and is refused.
"""

from __future__ import annotations

import os

DATABRICKS_HOST = os.environ.get(
    "DATABRICKS_HOST", "adb-7405618436278207.7.azuredatabricks.net"
).replace("https://", "").rstrip("/")
GATEWAY_ROUTE = "/ai-gateway/anthropic"

_SERVICE_PREFIX = "system.ai."
_LEGACY_PREFIX = "databricks-"


def legacy_name(model: str) -> str:
    """The pre-gateway endpoint name of the same model:
    system.ai.claude-haiku-4-5 -> databricks-claude-haiku-4-5. Anything else is
    returned unchanged."""
    if model.startswith(_SERVICE_PREFIX):
        return _LEGACY_PREFIX + model[len(_SERVICE_PREFIX):]
    return model


def same_model_versions(version: str) -> list[str]:
    """A "<model>/<prompt version>" stamp plus the identical stamp under the
    model's legacy endpoint name. Rows written before the move to the gateway carry
    databricks-claude-*; it is the same model, so they still count as current —
    without this, renaming the model would send every done row back through it."""
    model, sep, rest = version.partition("/")
    legacy = legacy_name(model)
    return [version] if legacy == model else [version, f"{legacy}{sep}{rest}"]


def _host_and_token(backend: str) -> tuple[str, str]:
    from databricks.sdk.core import Config
    if backend == "databricks":
        cfg = Config()
        token = cfg.authenticate()["Authorization"].split(" ", 1)[1]
        return cfg.host.replace("https://", "").rstrip("/"), token
    if os.environ.get("DATABRICKS_SERVING_TOKEN"):
        return DATABRICKS_HOST, os.environ["DATABRICKS_SERVING_TOKEN"]
    saved = os.environ.pop("DATABRICKS_TOKEN", None)   # SQL-only PAT: refused by the gateway
    try:
        cfg = Config(host=f"https://{DATABRICKS_HOST}", auth_type="external-browser")
        return DATABRICKS_HOST, cfg.authenticate()["Authorization"].split(" ", 1)[1]
    finally:
        if saved is not None:
            os.environ["DATABRICKS_TOKEN"] = saved


def get_client(backend: str, max_retries: int = 8, timeout: float | None = None):
    """An anthropic.Anthropic client on the Unity AI Gateway. Tokens last about an
    hour, so a long run should build a fresh client per wave."""
    import anthropic
    host, token = _host_and_token(backend)
    kwargs = {"timeout": timeout} if timeout is not None else {}
    return anthropic.Anthropic(
        api_key="unused",
        base_url=f"https://{host}{GATEWAY_ROUTE}",
        default_headers={"Authorization": f"Bearer {token}"},
        max_retries=max_retries,   # backs off + honors retry-after on 429/5xx
        **kwargs,
    )
