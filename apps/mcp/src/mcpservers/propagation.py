"""Trace context across the MCP boundary. ANSWERED — the record of the experiment.

This module used to pose a question and raise `NotImplementedError` in two stub
functions. The question was answered on 2026-09-10, re-checked on 2026-09-11,
and corrected on 2026-09-13 (LEARNINGS.md). The stubs are gone. What remains is
the answer, kept next to the code so nobody re-opens the question by reading a
stale docstring.

---------------------------------------------------------------------------
THE QUESTION

The Model Context Protocol's base specification says nothing about propagating
trace context in the JSON-RPC envelope. So when the workflow calls a tool here,
either an instrumented client puts `traceparent` somewhere the server reads it
and the tool span parents correctly, or nothing does and the trace breaks at
the agent → tool boundary.

---------------------------------------------------------------------------
THE ANSWER, AS FIRST RECORDED (2026-09-10): it propagates, and it is the SDK

The `mcp` 2.x Python SDK instruments both ends. Its client emits an
`MCP send tools/call <name>` span; its server emits `tools/call <name>` as a
child. On run `f66e8e29c66d` every server-side tool span was parented onto the
workflow's client span, with zero spans whose parent was missing. Nothing in
this package or in the workflow's `mcp_client.py` touches trace context.

---------------------------------------------------------------------------
THE CORRECTION (2026-09-13): it is in `_meta`, not in HTTP headers

The first record said the context travelled "over HTTP headers" and that a
stdio transport would break the trail silently. That was inferred, not read,
and it is wrong. Read from the installed SDK (2.2.0):

    mcp/shared/jsonrpc_dispatcher.py   inject_trace_context(out_meta)
        "SEP-414: inject W3C trace context; `_meta` stays on the wire
         even with a no-op tracer."
    mcp/server/_otel.py                context=extract_trace_context(ctx.meta)

The client writes `traceparent` / `tracestate` into the JSON-RPC request's
`params._meta`; the server's OpenTelemetry middleware extracts from the same
place. Headers are not involved, which is how this was caught: a header check
added on 2026-09-13 warned on a call whose stored span was correctly parented.

SEP-414 is not SDK-private. It is an MCP specification enhancement, status
Final, merged 2026-02-26, and it reserves three un-prefixed `_meta` keys:
`traceparent`, `tracestate` and `baggage`. The third is the standard W3C
carrier for "on whose behalf", which gives chapter 6 a defined place to put
identity on this hop.

Consequences, more useful than the original claim:

  - Propagation is transport-independent. The same SDK over stdio carries the
    same `_meta`, so the audit trail survives a transport swap.
  - It is *implementation*-dependent instead. A client or server that does not
    honour SEP-414 (another language's SDK before it adopted it, a hand-rolled
    client, an older `mcp` release) drops the context, whatever the transport.
  - The right assertion on the server is therefore not "was there a header"
    but "does my span have a remote parent". That is what
    `caller_trace_present` checks, and what `server_base.join_caller_trace`
    warns on when it is false.

The separate-pods design decision stands for a different reason than the one
first given: a real network hop is what makes propagation *observable* as two
services in one trace, rather than continuous by accident of one process.

What the conventions still cannot express at this boundary is recorded in
CONTRIBUTIONS.md: item 10 (OpenLIT's client spans omit the tool name and
double-count), and the `gen_ai.tool.call.arguments` question in the phase 1
write-up (the arguments are content, so a no-content posture keeps only the
tool's name as the record of data access).
"""

from opentelemetry import trace


def caller_trace_present() -> bool:
    """True if the current span joined a caller's trace.

    Inside a tool body the current span is the SDK's `tools/call <name>` server
    span. Its parent is a remote span context exactly when the request carried
    valid trace context in `_meta` and the SDK extracted it. `is_remote` is the
    W3C propagation marker, so this is transport-agnostic and does not care
    where the context travelled. Read-only.
    """
    parent = getattr(trace.get_current_span(), "parent", None)
    return bool(parent is not None and parent.is_valid and parent.is_remote)
