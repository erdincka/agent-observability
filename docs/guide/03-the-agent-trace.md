# 3. The agent trace

**Question it answers:** what did the agent do, as a tree: workflow, agents, model calls,
in order, with outcomes. And can you trust that the tree is complete?
**Status:** built.
**Tools:** LangGraph, OpenLIT SDK, LiteLLM, ClickHouse.

## Run

```bash
make postgres
make workflow-image
make workflow-probe            # one node, one model call: is it my graph or my instrumentation?
make workflow-triage           # the real thing: INCIDENT= and ROUTE=local|remote
```

## Look

Take the trace id from the run's log line, then:

```bash
# the tree, by service
make ch-query Q="SELECT ServiceName, SpanName, Duration/1e6 AS ms FROM otel_traces WHERE TraceId='<id>' ORDER BY Timestamp"

# is the tree whole? zero is the only acceptable answer
make ch-query Q="SELECT count() FROM otel_traces WHERE TraceId='<id>' AND ParentSpanId!='' AND ParentSpanId NOT IN (SELECT SpanId FROM otel_traces WHERE TraceId='<id>')"
```

## What you should see

For the probe, seven spans, two services, one trace:

```
invoke_workflow LangGraph        triage-workflow
└─ invoke_agent answer           triage-workflow
   └─ chat local                 triage-workflow
      └─ POST                    triage-workflow
         └─ POST /v1/chat/...    litellm-gateway
            ├─ auth              litellm-gateway
            └─ chat local        litellm-gateway
```

For a triage run, over a hundred spans across five services, and a dangling-parent count
of zero. On the run used to close phase 1: 133 spans, zero dangling.

## What it means

**OpenLIT instruments LangGraph out of the box.** `invoke_workflow` and one
`invoke_agent <node>` span per node, with `gen_ai.agent.name`, at no cost. The brief
expected this to be a gap to hand-roll; it was not.

**The same model call is described twice, and both spans carry full usage.** The SDK
instruments the client; the gateway instruments itself. Sum `gen_ai.usage.input_tokens`
over a trace and a 36-token call reports 72. Neither component is wrong. The conventions
have no way to say "this span is an intermediary's view of an operation another span
already reports".

**A trace can look complete and not be.** For most of phase 1, every model call's LLM span
was started by OpenLIT and never exported, because an unguarded `ContextVar.reset()` in
its LangChain handler raises across asyncio Tasks and skips `_end_span`. Agent names were
on one span and token counts on another, with a hole between them exactly where they
needed to join. The tree "looked right". The dangling-parent query above is what caught
it, and it is the check to run before believing any trace.

**The SDK's content default is the opposite of the gateway's.** `openlit.init()` captures
prompts and completions unless told not to. The gateway is `no_content`. Both write to the
same table. The workflow and the tool servers pass `capture_message_content=False`
explicitly for this reason.

## Where it breaks

- Double counting across client and gateway. CONTRIBUTIONS item 5.
- The span leak. Guarded locally in `apps/workflow/src/workflow/telemetry.py`, before
  `openlit.init()`, because the handler closes over the helper at init time.
  CONTRIBUTIONS item 7.
- Content capture default. CONTRIBUTIONS item 4.
- The Postgres checkpointer's writes are classified as `vectordb` operations and its reads
  as `retrieval`. Roughly forty spans a run, in a category this lab does not have.
- After a model call, "the current span" in that Task is OpenLIT's ended LLM span. Writes
  to it are silently dropped. Chapter 5 is built around this.

## In an enterprise

Audit the SDK's posture, not only the gateway's. An operator who verified the component
whose job is being the policy boundary, and stopped there, would have full prompts in the
store from the application side, with nothing to tell them.

"No error spans and the tree looks right" is not evidence of a complete trace. A count of
spans whose parent was never exported is. Put that query in front of anyone who will read
these traces for compliance.

## Read more

- LEARNINGS.md: *Step 4* (2026-09-09), *Wiring the checkpointer* (2026-09-10),
  *Per-agent attribution* (2026-09-11).
- `apps/workflow/src/workflow/telemetry.py`, whose docstrings are the full account.
