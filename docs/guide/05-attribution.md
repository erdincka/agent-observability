# 5. Attribution per agent

**Question it answers:** which agent consumed what, on which route, with how many calls,
was reasoning used, and was the output usable? All per agent, per run, filterable.
**Status:** built. Attribute names aligned with the conventions on 2026-09-13.
**Tools:** LangGraph, OpenTelemetry API, LiteLLM, ClickHouse, OpenLIT UI.

## Run

```bash
make workflow-triage ROUTE=local
make workflow-triage ROUTE=remote     # a reasoning model, if a key is present
```

## Look

```bash
make ch-query Q="SELECT SpanAttributes['triage.agent'] AS agent, SpanAttributes['gen_ai.usage.input_tokens'] AS input, SpanAttributes['gen_ai.usage.output_tokens'] AS output, SpanAttributes['gen_ai.usage.reasoning.output_tokens'] AS reasoning, SpanAttributes['triage.outcome'] AS outcome FROM otel_traces WHERE TraceId='<id>' AND SpanAttributes['gen_ai.operation.name']='invoke_agent' AND SpanAttributes['gen_ai.usage.input_tokens']!=''"
```

The filter on `gen_ai.operation.name` is the point: OpenLIT's own `invoke_agent` spans
carry no usage keys, so this selects exactly the workflow's per-agent spans, and summing
them does not double-count against the gateway.

```bash
# reconcile against the gateway for the same run
make ch-query Q="SELECT ServiceName, sum(toUInt64OrZero(SpanAttributes['gen_ai.usage.input_tokens'])) FROM otel_traces WHERE TraceId='<id>' AND (SpanAttributes['gen_ai.operation.name']='invoke_agent' OR ServiceName='litellm-gateway') AND SpanAttributes['gen_ai.usage.input_tokens']!='' GROUP BY ServiceName"
```

## What you should see

One row per agent. The first remote run looked like this:

| agent | calls | in | out | reasoning | finish | outcome |
| :- | -: | -: | -: | -: | :- | :- |
| retriever | 6 | 12372 | 454 | 313 | `tool_calls` ×6 | ok |
| analyser | 1 | 1513 | 4096 | 4792 | `length` | truncated |
| reporter | 1 | 5179 | 1 | 1 | `stop` | empty |

The agent-side sums reconcile with the gateway's own figures over the run's model calls.
On the run that closed phase 1, both sides said 7204 input and 366 output.

## What it means

**Each agent writes to a span it owns, by reference.** The obvious implementation, stamping
usage onto "the current span" inside the node, recorded nothing at all: after a model
call, the current span is OpenLIT's already-ended LLM span, and writes to it vanish
without an error. Never look up an attribution target in ambient context while a third
party is mutating that context.

**Outcome is a first-class attribute, worst-first.** `truncated`, `empty`, `degraded`, `ok`.
`degraded` means the node finished on less than it should have had: a tool server
unreachable, or the round cap reached, with the reason in `triage.degraded_reason`. The
reporter above returned one token with `finish_reason: stop`, an empty report scored as
a clean success by every finish-reason check. A completed run, a normal stop, no error,
no output: this is the project's recurring failure shape, and `triage.outcome` exists so
it is one filter away.

**Reasoning tokens were the figure nobody captured.** They are in the provider's response
and on no span in the stack until the agent span recorded them. On a reasoning route they
can exceed `output_tokens` on the same call. The gateway, the natural place for a platform
team to see this, emits nothing.

**The baseline is a distribution, not a golden trace.** `temperature=0` and a seed reach
the model and still do not make two runs identical on CPU inference. Tool selection is
left to the model on purpose, so what gets compared across runs is domains covered, calls
made, evidence items and tokens, all of which are on the spans.

## Where it breaks

- The OpenLIT UI's token and cost columns read zero for every run, because its SQL sums
  `gen_ai.usage.total_tokens` and `gen_ai.usage.cost`, neither of which a current-semconv
  producer emits. Following the spec is what zeroes the panel. CONTRIBUTIONS item 8.
- The UI can filter by service, status, trace id and time. It cannot filter by span name
  or attribute, and its service filter is span-level, so filtering to the workflow strips
  the gateway and tool spans out of traces they belong to.
- Until 2026-09-13 the agent spans used a local name for reasoning tokens where a
  standard one existed since semconv v1.41.0, and lacked `gen_ai.operation.name`, so the
  documented aggregation did not work. Runs before that date carry the old names.
- Until the same date the retriever's early exits stamped no outcome at all, so the worst
  failures were the ones a `triage.outcome != 'ok'` filter could not find.

## In an enterprise

"By how much" is per agent, per route, per project, and it is tokens, not currency. Cost
is a pricing decision layered on top and belongs to whoever owns the chargeback model.
Neither route in this lab produces a non-zero cost, and that turned out to be the more
honest demonstration.

Per-model budgets leak through the route abstraction. The workflow names a route and never
a model, which is right, but token caps are a model property, and a reasoning model needs
four times the output budget of a 3B model. Expect per-route tuning to live somewhere the
route owner controls.

## Read more

- LEARNINGS.md: *A reasoning model fails by writing fluently* (2026-09-10), *What OpenLIT's
  telemetry page can actually filter* (2026-09-10), *Per-agent attribution* (2026-09-11).
- `apps/workflow/src/workflow/triage_graph.py`, `_Usage`.
