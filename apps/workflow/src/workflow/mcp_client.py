"""MCP tool access for the workflow — the client half of the agent → tool hop.

Hand-rolled on the `mcp` SDK rather than a LangChain adapter package, for one
reason: an adapter owns the HTTP client, and the HTTP client is where
`traceparent` would have had to go if the SDK had not already carried it. It
does — the `mcp` 2.x client injects W3C trace context into every JSON-RPC
request's `_meta` (SEP-414) and the server extracts it there, so nothing here
touches a header and the transport does not matter. The record of that
experiment, including the correction, is `apps/mcp/src/mcpservers/propagation.py`.
Keeping the transport in our own hands still matters: it is where chapter 6's
identity header will go.

Tools reach the model as raw OpenAI-format dicts built from what each server
advertises. `bind_tools` passes those through untouched, so there is no second
schema vocabulary to keep in step with the servers.

Connection failures are deliberately non-fatal. One unreachable tool server
degrades the evidence available to the retriever; it does not end the run. That
is the useful behaviour in a lab, because the trace then shows a triage
completed on partial evidence rather than showing nothing at all.

For most of phase 1 that paragraph was false (TODO item 1). The SDK's transport
connects inside an anyio task group; a failed connect cancels that group's
scope, so the awaiting `initialize()` received a `CancelledError` that
`except Exception` never sees, the exception left the `async with`, and one
shared `AsyncExitStack` tore down the healthy sessions on the way out. The
transport's exit then re-raised the real error as an `ExceptionGroup`. Fixed
2026-09-13 by giving each server its own exit scope and classifying what that
scope's close raises — see `_connect_one` — with the repro in TODO.md as the
test (`make mcp-degrade-test`).
"""

from __future__ import annotations

import json
import logging
import os
from contextlib import AsyncExitStack, asynccontextmanager
from dataclasses import dataclass, field
from typing import Any, AsyncIterator, Mapping

import anyio
import httpx2
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client
from mcp.shared._httpx_utils import create_mcp_http_client

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


class _Unreachable(Exception):
    """A server could not be connected, and the reason, already classified."""


async def _connect_one(
    name: str,
    url: str,
    headers: Mapping[str, str] | None,
) -> tuple[AsyncExitStack, ClientSession, Any]:
    """Connect to one server on its own exit scope.

    Returns the scope (still open, holding the transport and the session), the
    session, and the tool listing. Raises `_Unreachable` with a classified
    reason if the server cannot be used, after closing the scope. Re-raises a
    genuine cancellation untouched.

    The shape is the fix for TODO item 1. Everything the SDK opens for this
    server lives on `scope`, so a failure here cannot unwind another server's
    session. The interesting part is the `except BaseException`: under an
    anyio task group a transport failure reaches this coroutine as a
    *cancellation*, not as the underlying error. The error itself only exists
    once the task group exits, which is what `scope.aclose()` does. So the
    close is not cleanup, it is the diagnosis: what it raises is what actually
    went wrong, and that is what gets classified.
    """
    scope = AsyncExitStack()
    try:
        client = create_mcp_http_client(
            headers=dict(headers or {}),
            # Connect/write/pool bounded so a black-holing server degrades
            # rather than hanging the run. Read stays long: SSE streams.
            timeout=httpx2.Timeout(settings.mcp_connect_timeout, read=300.0),
        )
        await scope.enter_async_context(client)
        read, write = await scope.enter_async_context(
            streamable_http_client(url, http_client=client)
        )
        session = await scope.enter_async_context(ClientSession(read, write))
        # Only the *operations* get an anyio timeout. Wrapping the context
        # entries above in `fail_after` would exit its cancel scope while the
        # SDK's task-group scope (opened by the generator) is still active,
        # which anyio rejects as an out-of-order scope exit.
        with anyio.fail_after(settings.mcp_connect_timeout):
            await session.initialize()
            listing = await session.list_tools()
        return scope, session, listing
    except BaseException as exc:  # noqa: BLE001 - classified below, never swallowed blindly
        raise _Unreachable(await _diagnose(scope, exc)) from None


async def _diagnose(scope: AsyncExitStack, exc: BaseException) -> str:
    """Close a failed server's scope and say why it failed.

    Closing the scope exits the SDK's task groups. If the failure was theirs,
    that exit raises an `ExceptionGroup` carrying the real error, replacing
    the bare cancellation we caught. If the cancellation was genuine — the
    whole run being cancelled — the exit re-raises it, and so do we: an outer
    cancellation must never be reported as "server unreachable".
    """
    try:
        await scope.aclose()
    except BaseException as from_close:  # noqa: BLE001 - this is the real error
        exc = from_close

    if isinstance(exc, BaseExceptionGroup):
        plain, other = exc.split(Exception)
        if other is not None:
            # A cancellation (or worse) inside the group: not ours to absorb.
            raise other
        leaves = _leaves(plain) if plain is not None else []
        return "; ".join(f"{type(e).__name__}: {e}" for e in leaves) or "unknown"
    if isinstance(exc, TimeoutError):
        return f"timed out after {settings.mcp_connect_timeout}s"
    if isinstance(exc, Exception):
        return f"{type(exc).__name__}: {exc}"
    raise exc  # CancelledError or another BaseException: genuine, propagate


def _leaves(group: BaseExceptionGroup) -> list[BaseException]:
    out: list[BaseException] = []
    for e in group.exceptions:
        out.extend(_leaves(e) if isinstance(e, BaseExceptionGroup) else [e])
    return out


async def _close_scope(name: str, scope: AsyncExitStack) -> None:
    """Close one server's scope at the end of the run, without unwinding the rest.

    A server that died mid-run raises here. That is worth a log line and not
    worth the other servers' sessions, and definitely not worth the run.
    """
    try:
        await scope.aclose()
    except Exception as exc:  # noqa: BLE001 - teardown noise is not a run failure
        log.warning("closing mcp session %s raised: %s", name, exc)


@asynccontextmanager
async def tool_belt(
    servers: Mapping[str, str] | None = None,
    headers: Mapping[str, str] | None = None,
) -> AsyncIterator[ToolBelt]:
    """Connect to every tool server for the duration of the block.

    Sessions are opened once and closed on exit, each on its own scope. A
    server that cannot be reached is recorded in `belt.unreachable` and the
    run continues on the rest.

    `headers` are sent on every request to every server. This is where the
    per-agent credential for tool authorization goes (guide chapter 7). Trace
    context does not travel here — the SDK carries it in JSON-RPC `_meta`.
    """
    servers = dict(servers if servers is not None else default_servers())
    belt = ToolBelt()

    async with AsyncExitStack() as stack:
        for name, url in servers.items():
            try:
                scope, session, listing = await _connect_one(name, url, headers)
            except _Unreachable as exc:
                log.warning("mcp server %s unreachable at %s: %s", name, url, exc)
                belt.unreachable[name] = str(exc)
                continue
            stack.push_async_callback(_close_scope, name, scope)

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
