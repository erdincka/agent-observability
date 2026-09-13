"""Shared server construction for the three MCP tool servers.

Scaffolding. The one thing of interest is `join_caller_trace`, which no longer
joins anything — the `mcp` SDK does that — and instead reports when a tool
call arrives without trace context. See `propagation.py` for the record.
"""

import logging
import os
from typing import Any

from mcp.server.mcpserver import Context, MCPServer

from . import propagation
from .telemetry import init_telemetry

log = logging.getLogger(__name__)
_warned = False


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
