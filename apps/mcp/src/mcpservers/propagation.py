"""Trace context across the MCP boundary. INTENTIONALLY UNIMPLEMENTED — yours.

This is the piece worth writing by hand, and the reason the MCP servers are
separate pods speaking HTTP rather than stdio subprocesses. In-process, trace
context would stay continuous for free and prove nothing.

---------------------------------------------------------------------------
THE PROBLEM

The Model Context Protocol specification says nothing about propagating trace
context. There is no `traceparent` in the base spec — not in the JSON-RPC
envelope, not in the tool call schema, nowhere.

So when the workflow calls a tool here, one of two things happens and you need
to find out which:

  (a) The transport is HTTP, an instrumented HTTP client injects `traceparent`
      as an ordinary header, an instrumented server extracts it, and the tool
      span parents correctly by accident of the transport rather than by
      anything MCP does.

  (b) Nothing injects it, the server starts a fresh root span, and the trace
      breaks exactly at the agent → tool boundary — the one boundary the whole
      project claims to make visible.

Verify which before writing any code. `./scripts/gateway-trace.sh` shows what a
correctly joined trace looks like; the equivalent for a tool call is what you
are chasing.

---------------------------------------------------------------------------
WHY IT IS THE INTERESTING PART

If it is (a), the propagation works but MCP is not what makes it work — swap
the transport to stdio and the audit trail silently breaks. That is worth
saying out loud, because "our agent traces are complete" would then be a claim
about a transport choice nobody wrote down.

If it is (b), you are hand-rolling the bridge, and the shape you choose is a
concrete proposal: does trace context belong in the JSON-RPC `_meta` field, in
transport headers, or in the tool arguments? Each has different consequences for
a stdio transport, which has no headers at all.

Either answer is a CONTRIBUTIONS.md entry. The brief predicted this boundary
would be a contribution lane; this is where that gets tested.

---------------------------------------------------------------------------
WHAT TO WRITE

    extract_context(headers) -> attaches the incoming trace context, if any,
                                so tool spans parent onto the calling agent

    inject_context(headers)  -> the client-side counterpart, for the workflow

Both sides are yours. The servers already call `extract_context` for you, via
`server_base.join_caller_trace`, which is wired to hand you the request headers.

Two concrete hooks, both confirmed present in mcp 2.x:

  server side — `Context.headers` gives a tool the incoming HTTP headers
                directly. Under stdio it is empty, which is precisely the
                asymmetry worth writing about.

  client side — `streamable_http_client(url, http_client=...)` accepts a
                pre-configured `httpx2.AsyncClient`, which is where outbound
                headers would come from.
"""

from typing import Mapping


def extract_context(headers: Mapping[str, str]) -> None:
    """Attach incoming trace context. See this module's docstring."""
    raise NotImplementedError(
        "Yours to write. First find out whether trace context already survives "
        "the HTTP hop without it — the answer determines what this needs to do."
    )


def inject_context(headers: dict[str, str]) -> dict[str, str]:
    """Client-side counterpart, used by the workflow when calling a tool."""
    raise NotImplementedError("Yours to write — see extract_context.")
