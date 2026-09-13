"""Shared server construction for the three MCP tool servers.

Scaffolding. The one thing of interest is `join_caller_trace`, which no longer
joins anything — the `mcp` SDK does that — and instead reports when a tool
call arrives without trace context. See `propagation.py` for the record.
"""

import json
import logging
import os
import pathlib
from typing import Any

from mcp.server.mcpserver import Context, MCPServer
from opentelemetry import trace
from opentelemetry.trace import StatusCode

from . import propagation
from .telemetry import init_telemetry

log = logging.getLogger(__name__)
_warned = False

# ---------------------------------------------------------------- authz ----
# Per-role tool access, enforced here, at the tool server, because this is the
# data-access boundary. The policy is a JSON object {role: [tool, ...]} with
# "*" meaning every tool; a role absent from it can call nothing. Callers
# identify themselves with a bearer token; the token→role map comes from the
# environment (TOOL_TOKEN_<ROLE>=<token>), published from a Kubernetes Secret.
#
# Why a token and not the baggage: baggage says which agent is calling and on
# whose behalf, and it lands on the span for attribution. It is also whatever
# the caller chose to write. The token is a credential the server can check.
# In an enterprise the token would be a signed workload identity (SPIFFE, a
# JWT from the platform's issuer); a static bearer per role is the smallest
# thing that makes the distinction real.
POLICY_PATH = pathlib.Path(os.getenv("TOOL_POLICY_PATH", "/etc/mcp/policy.json"))
_TOKENS: dict[str, str] = {
    v: k[len("TOOL_TOKEN_"):].lower()
    for k, v in os.environ.items()
    if k.startswith("TOOL_TOKEN_") and v
}


def _policy() -> dict[str, list[str]]:
    try:
        return json.loads(POLICY_PATH.read_text())
    except FileNotFoundError:
        # No policy mounted: nothing is permitted. Fail closed, and say so once.
        return {}


def _role_of(ctx: Context) -> str:
    try:
        auth = (ctx.headers or {}).get("authorization") or ""
    except Exception:  # noqa: BLE001
        auth = ""
    token = auth.removeprefix("Bearer ").strip() if auth.startswith("Bearer ") else ""
    return _TOKENS.get(token, "anonymous")


def guard(ctx: Context, tool: str) -> None:
    """Per-call check: is this caller's role allowed to run this tool?

    Every tool calls this first. Both outcomes are recorded on the tool's
    span — `authz.decision`, `authz.role`, `authz.tool` — because an
    authorization layer that only records denials leaves "was this checked?"
    unanswerable for the calls it allowed. A denial also sets the span status
    to error and raises, so the client receives a tool error (not a crash)
    and the run degrades.

    The attribute names are local: the GenAI conventions have no
    authorization vocabulary. Flagged as such in the guide.
    """
    join_caller_trace(ctx)
    role = _role_of(ctx)
    allowed = _policy().get(role, [])
    decision = "allow" if ("*" in allowed or tool in allowed) else "deny"

    span = trace.get_current_span()
    span.set_attribute("authz.role", role)
    span.set_attribute("authz.tool", tool)
    span.set_attribute("authz.decision", decision)
    if decision == "deny":
        span.set_status(StatusCode.ERROR, f"tool {tool} denied for role {role}")
        log.warning("denied: role=%s tool=%s", role, tool)
        raise PermissionError(
            f"role '{role}' is not permitted to call '{tool}' "
            f"(policy: {POLICY_PATH})"
        )


def build_server(name: str) -> MCPServer:
    """Construct a server.

    In mcp 2.x the bind address is a `run()` argument rather than a constructor
    setting, so `serve()` below owns it.
    """
    init_telemetry(name)
    return MCPServer(name)


def serve(mcp: MCPServer) -> None:
    mcp.run(
        transport="streamable-http",
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8080")),
    )


def join_caller_trace(ctx: Context) -> None:
    """Report, once, if a tool call arrived with no trace context.

    Historical name. This used to call a propagation stub; the `mcp` 2.x SDK
    turned out to extract `traceparent` and parent the tool span itself, so
    there is nothing to join (see `propagation.py`). What is worth keeping is
    the inverse check: every call from an SEP-414-aware client carries context
    in `_meta`, so a tool span with no remote parent is a broken audit trail —
    a client that does not propagate, or a proxy that rewrote the request.
    Warn on the first one; the span itself, a root with no parent, is the
    durable evidence. Transport-agnostic: `_meta` travels over stdio too.
    """
    global _warned
    if not propagation.caller_trace_present() and not _warned:
        _warned = True
        log.warning(
            "tool call arrived without trace context — its span is a root, not "
            "a child of the calling agent. The client did not inject "
            "traceparent into _meta (SEP-414); see propagation.py."
        )


def tool_result(payload: Any) -> Any:
    """Placeholder for a single point to shape tool output if it ever matters."""
    return payload
