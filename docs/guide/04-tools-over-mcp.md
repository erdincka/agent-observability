# 4. Tools over MCP

**Question it answers:** which tools did the agent call, and does the trace survive the
hop from agent to tool? With content off, what does the trace retain about data access?
**Status:** built, with one honesty fix in progress (TODO item 1).
**Tools:** MCP Python SDK over streamable HTTP, OpenLIT, Prometheus.

## Run

```bash
make step5           # build the image, deploy mcp-metrics, mcp-changes, mcp-runbooks, probe them
make workflow-triage # then look at the same trace as chapter 3
```

## Look

```bash
make ch-query Q="SELECT ServiceName, SpanName, SpanAttributes['gen_ai.tool.name'] AS tool FROM otel_traces WHERE TraceId='<id>' AND SpanName LIKE '%tools/call%' ORDER BY Timestamp"
```

## What you should see

Server-side tool spans parented onto the workflow's client spans, in one trace, down to
the HTTP request the tool itself made:

```
triage-workflow  MCP send tools/call active_alerts
  mcp-metrics    tools/call active_alerts
    mcp-metrics  GET                             <- the Prometheus query
```

## What it means

**Trace context crosses the agent → tool hop, and the SDK is what carries it.** The
`mcp` 2.x SDK instruments both ends: the client writes W3C `traceparent` into the JSON-RPC
request's `_meta` field, under MCP SEP-414 (Final, February 2026), and the server's middleware extracts
it from the same place. The propagation bridge the brief expected to hand-write was never
needed.

**So "our agent traces are complete" is a claim about the implementation at both ends,
not about the transport.** The first record of this experiment said the context travelled
in HTTP headers and that stdio would break it. It was wrong, and it was caught by a header
check that warned on a call whose span was correctly parented. `_meta` travels over stdio
just as well. What breaks the trail is a client or server that does not implement
SEP-414: another language's SDK before it adopted it, a hand-rolled client, an older
release. The tool servers now warn when a call arrives with no remote parent, whatever
the transport. The separate pods still earn their place: a real network hop is what makes
propagation observable as two services in one trace.

**With content off, the tool's name is the only data-access signal the trace keeps.** The
standard attribute for what a tool was called with, `gen_ai.tool.call.arguments`, is
flagged as potentially sensitive and withheld under `no_content`. The trace knows the
agent queried Prometheus; it does not know which metric. Chapter 8 is about what can be
retained in a redacted form.

**A tool returning a list arrives as one content block per element.** The client's join
over those blocks is what made a list look like a 1500-character word. Fixed on the
client, where the fault was, not on the server, where the instinct pointed.

## Where it breaks

- OpenLIT's MCP client instrumentation records every operation twice and never names the
  tool on its tool-call spans. The name appears two levels down in the SDK's span, and on
  the server. CONTRIBUTIONS item 10.
- Two vocabularies on one hop: the SDK uses the GenAI registry's `mcp.*` names, OpenLIT
  uses its own.
- **`tool_belt` aborts the run when one server is unreachable**, the opposite of what its
  docstring promises. Reproduced on 2026-09-13: the SDK's connect runs in a task group,
  the failure reaches the caller as a cancellation that `except Exception` cannot see,
  and the shared exit stack tears down the healthy sessions on the way out. One dead tool
  server should degrade the evidence, not end the run. This matters for chapter 7, where
  a denied tool must look like a degraded run, not a crashed one. TODO item 1.
- The tool servers now warn when a call arrives without trace context, the useful inverse
  of the warning the propagation stubs used to emit. A root span with no parent on a tool
  server is the durable evidence that the trail broke.

## In an enterprise

A tool call is the data-access boundary. It is more sensitive than the prompt, because
its arguments are far more likely to hold identifiers, account numbers or query predicates
than a chat message is. The tool server is therefore the right place to record *what was
accessed* in a form that is not content: a resource identifier, a hash of the arguments,
a classification. That is a design decision for chapter 8, and the tool servers in this
lab are where it will be made.

## Read more

- LEARNINGS.md: *Step 5* (2026-09-09), *The triage graph runs* (2026-09-10) and its
  2026-09-11 caveat, *Phase 1 write-up* (2026-09-13).
- `apps/mcp/src/mcpservers/propagation.py`, `apps/workflow/src/workflow/mcp_client.py`.
