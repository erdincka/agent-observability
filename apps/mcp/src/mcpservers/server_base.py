"""Shared server construction for the three MCP tool servers.

Scaffolding. The one interesting thing it does is call `extract_context` from
`propagation.py` defensively, so the servers run today with that function still
unimplemented and light up the moment it exists.
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
    """Best-effort attach of the caller's trace context.

    Deliberately non-fatal while `propagation.extract_context` is unimplemented:
    the servers are useful before the bridge exists, and a hard failure here
    would make it impossible to run the experiment that determines what the
    bridge should do.

    Once implemented, this is the seam where a tool span becomes a child of the
    calling agent's span rather than the root of an orphan trace.
    """
    global _warned
    # mcp 2.x exposes the request headers directly on Context. Under stdio there
    # are none, which is the whole reason these servers speak HTTP.
    try:
        headers = dict(ctx.headers or {})
    except Exception:  # noqa: BLE001 - never let telemetry plumbing break a tool
        headers = {}

    try:
        propagation.extract_context(headers)
    except NotImplementedError:
        if not _warned:
            _warned = True
            log.warning(
                "trace context bridge not implemented — tool spans may start a "
                "new trace instead of joining the caller's. "
                "traceparent present on this request: %s",
                "traceparent" in {k.lower() for k in headers},
            )


def tool_result(payload: Any) -> Any:
    """Placeholder for a single point to shape tool output if it ever matters."""
    return payload
