"""MCP tool access for the workflow — the client half of the agent → tool hop.

Hand-rolled on the `mcp` SDK rather than a LangChain adapter package, for one
reason: an adapter owns the HTTP client, and the HTTP client is exactly where
`traceparent` would have to go. Keeping the transport in our own hands is what
leaves `propagation.inject_context` implementable at all — see
`apps/mcp/src/mcpservers/propagation.py`, and the seam marked below.

Tools reach the model as raw OpenAI-format dicts built from what each server
advertises. `bind_tools` passes those through untouched, so there is no second
schema vocabulary to keep in step with the servers.

Connection failures are deliberately non-fatal. One unreachable tool server
degrades the evidence available to the retriever; it does not end the run. That
is the useful behaviour in a lab, because the trace then shows a triage
completed on partial evidence rather than showing nothing at all.
"""

from __future__ import annotations

import json
import logging
import os
from contextlib import AsyncExitStack, asynccontextmanager
from dataclasses import dataclass, field
from typing import Any, AsyncIterator, Mapping

from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from .settings import settings

log = logging.getLogger(__name__)

# A single tool result has to fit in a 3B model's context alongside everything
# else. `active_alerts` alone returns several KB of JSON, so an uncapped result
# silently costs the retriever its remaining rounds. Truncation is visible in
# the evidence string rather than hidden.
MAX_RESULT_CHARS = 1500


@dataclass
class ToolBelt:
    """Every tool from every reachable server, plus the routing to call them."""

    specs: list[dict[str, Any]] = field(default_factory=list)
    _sessions: dict[str, ClientSession] = field(default_factory=dict)
    _owner: dict[str, str] = field(default_factory=dict)
    unreachable: dict[str, str] = field(default_factory=dict)

    def server_of(self, tool_name: str) -> str:
        return self._owner.get(tool_name, "unknown")

    async def call(self, tool_name: str, arguments: dict[str, Any]) -> str:
        """Invoke one tool and flatten its result to text.

        Never raises. A tool that fails returns its error as the result, so the
        model gets to react to it and the failure lands in the evidence list
        instead of unwinding the graph.
        """
        server = self._owner.get(tool_name)
        if server is None:
            return f"ERROR: no such tool {tool_name!r}"

        try:
            result = await self._sessions[server].call_tool(tool_name, arguments)
        except Exception as exc:  # noqa: BLE001 - a tool failing is data, not a crash
            log.warning("tool %s on %s failed: %s", tool_name, server, exc)
            return f"ERROR calling {tool_name}: {exc}"

        # mcp 2.x names these snake_case on the model; camelCase survives only
        # as the wire alias. A getattr(..., default) here would have left
        # is_error permanently False and silently mislabelled every tool error.
        #
        # A tool returning `list[str]` or `list[dict]` comes back as one
        # TextContent block PER ELEMENT, plus a faithful `structured_content`.
        # Joining the blocks with "" — the obvious first guess — runs every
        # element together: 50 Prometheus metric names arrive as one
        # 1500-character word, and the model cannot read it. The servers are
        # blameless; this is the client's decode. Prefer the structured form,
        # which is the shape the tool actually returned, and fall back to
        # newline-joined blocks.
        if result.structured_content is not None:
            payload = result.structured_content
            # FastMCP wraps a non-dict return in {"result": ...}; unwrap so the
            # model sees the tool's own shape rather than the protocol's.
            if isinstance(payload, dict) and set(payload) == {"result"}:
                payload = payload["result"]
            text = json.dumps(payload, indent=2, default=str)
        else:
            text = "\n".join(
                getattr(block, "text", "") for block in (result.content or [])
            ).strip()

        if result.is_error:
            text = f"ERROR from {tool_name}: {text}"
        if len(text) > MAX_RESULT_CHARS:
            text = text[:MAX_RESULT_CHARS] + f"... [truncated at {MAX_RESULT_CHARS} chars]"
        return text


DOMAINS = ("metrics", "changes", "runbooks")


def default_servers() -> dict[str, str]:
    """The three evidence domains, one streamable-HTTP endpoint each.

    `MCP_METRICS_URL` / `MCP_CHANGES_URL` / `MCP_RUNBOOKS_URL` override
    individually, which is what makes a run against port-forwarded services
    possible: three ClusterIPs on the same port cannot be expressed by varying
    SERVICE_DOMAIN alone, and a local run that cannot reach the tool servers
    exercises none of the code worth exercising.
    """
    servers = {}
    for name in DOMAINS:
        servers[name] = os.getenv(
            f"MCP_{name.upper()}_URL",
            f"http://mcp-{name}.{settings.service_domain}:{settings.mcp_port}/mcp",
        )
    return servers


@asynccontextmanager
async def tool_belt(
    servers: Mapping[str, str] | None = None,
) -> AsyncIterator[ToolBelt]:
    """Connect to every tool server for the duration of the block.

    Sessions are opened once and closed on exit. The previous version built
    them inside the node on every call and never closed them.
    """
    servers = dict(servers if servers is not None else default_servers())
    belt = ToolBelt()

    async with AsyncExitStack() as stack:
        for name, url in servers.items():
            try:
                # ---- propagation seam ------------------------------------
                # `streamable_http_client` accepts `http_client=` (a
                # pre-configured httpx2.AsyncClient). That argument is the only
                # place outbound `traceparent` can come from, and it is the
                # client half of the experiment in
                # apps/mcp/src/mcpservers/propagation.py. Left at the default
                # on purpose: whether trace context already survives this hop
                # unaided is the question that file says to answer first, and
                # wiring an injector here now would destroy the measurement.
                read, write = await stack.enter_async_context(
                    streamable_http_client(url)
                )
                session = await stack.enter_async_context(ClientSession(read, write))
                await session.initialize()
                listing = await session.list_tools()
            except Exception as exc:  # noqa: BLE001 - degrade, do not abort
                log.warning("mcp server %s unreachable at %s: %s", name, url, exc)
                belt.unreachable[name] = str(exc)
                continue

            belt._sessions[name] = session
            for tool in listing.tools:
                if tool.name in belt._owner:
                    log.warning(
                        "tool name %r exported by both %s and %s — keeping %s",
                        tool.name,
                        belt._owner[tool.name],
                        name,
                        belt._owner[tool.name],
                    )
                    continue
                belt._owner[tool.name] = name
                belt.specs.append(
                    {
                        "type": "function",
                        "function": {
                            "name": tool.name,
                            "description": tool.description or "",
                            "parameters": tool.input_schema
                            or {"type": "object", "properties": {}},
                        },
                    }
                )

        log.info(
            "tool belt ready: %d tools from %s%s",
            len(belt.specs),
            sorted(belt._sessions),
            f", unreachable: {sorted(belt.unreachable)}" if belt.unreachable else "",
        )
        yield belt
