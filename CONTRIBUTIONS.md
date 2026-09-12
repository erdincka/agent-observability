# CONTRIBUTIONS

Upstream gaps hit while building this lab, logged the moment we hit them — not
reconstructed afterwards, because by then the workaround looks like the design.

For each entry: which project, what is missing or broken, what we did instead, and what
kind of contribution it looks like (docs fix / example / bug report / code change).

## Open

### 1. Perses — ClickHouse datasource has no TraceQuery plugin

**Project:** [perses/plugins](https://github.com/perses/plugins)
**Status:** Verified at source level, 2026-09-09. Tracked upstream by an existing issue, [perses/perses#4202](https://github.com/perses/perses/issues/4202).
PR opened as a draft on 2026-09-12: [perses/plugins#813](https://github.com/perses/plugins/pull/813).

The project brief suspected this; it checks out, and it is stronger than "the docs
don't mention it".

Evidence:
- `clickhouse/src/queries/` contains exactly two query plugins:
  `click-house-log-query` and `click-house-time-series-query`. There is no trace query.
- `clickhouse/sdk/go/` contains `datasource` and `query` only.
- The published docs list three ClickHouse SDKs — datasource, log query, time series
  query — and nothing else.

What makes it a gap rather than a design choice: the same repository already ships
`tracetable`, `tracingganttchart` and `flamechart` panels, plus `jaeger` and `tempo`
datasource plugins. The trace *visualisation* surface exists and is fed by TraceQuery
implementations from other datasources. ClickHouse simply has no plugin capable of
feeding it, even though ClickHouse is a common OTel trace store — including in this
project, where the OTel Collector writes traces to ClickHouse via `clickhouseexporter`.

Consequence for this lab: phase 3 cannot render traces in Perses from ClickHouse today.
The fallbacks are to point Perses at Jaeger for the trace view only (adding a component
the project deliberately excluded), or to build the plugin.

**Contribution type:** code change — a new `click-house-trace-query` plugin, mirroring
the structure of the existing log query plugin and the TraceQuery contract used by the
Jaeger and Tempo plugins. Non-trivial but well-bounded, and it is the single highest-value
target in this project.

**Filed as — no new issue.** The gap was already tracked upstream as [perses/perses#4202](https://github.com/perses/perses/issues/4202),
"Plugin Request: Clickhouse full support", opened by a maintainer and labelled `help wanted`. One of its
tasks is "a generic trace explorer where Clickhouse traces could be used as a datasource", and a TraceQuery
plugin is the prerequisite for it. We commented there on 2026-09-11 rather than opening a duplicate, and a
maintainer (@Nexucis) replied the same day that no one is working on it. The code went straight to a PR:
[perses/plugins#813](https://github.com/perses/plugins/pull/813), `[FEATURE] ClickHouse: add trace query plugin`, opened as a draft on 2026-09-12.

**What the PR does:** `ClickHouseTraceQuery` reads the `clickhouseexporter` `otel_traces` schema. A trace ID
returns the whole trace, for the Tracing Gantt Chart; a SQL query returning one row per span is grouped into
search results, for the Trace Table. That is the contract the Tempo plugin already uses, so `${traceId}`
drill-down links work unchanged. CUE schema, Go SDK, docs and tests are included, and it was verified end to end
(Collector → ClickHouse → Perses) in a throwaway stack kept outside this repository.

**Decision flagged in the PR as the one most likely to change:** trace ID lookups filter on `TraceId` with no
time bound, so a trace opens from a link whatever the dashboard's time range, relying on the bloom filter index
the exporter creates. The exporter's `otel_traces_trace_id_ts` table would bound the scan on large tables, but it
only exists when the exporter created the schema, so depending on it would break custom tables and views. The
choice is documented in the plugin's data model docs and highlighted for the reviewers.

**Found along the way — noted in the PR, not filed:**
- The existing ClickHouse Go SDK docs (`docs/clickhouse/go-sdk/`) import a module path that doesn't exist
  (`github.com/perses/perses-plugins/clickhouse/sdk/go/v1/...`) and use builders the SDK doesn't have
  (`query.LogQuery`, `query.TimeSeriesQuery`, `query.Format`), and `docs/clickhouse/model.md` documents a
  `format` field that the query schemas reject. No existing issue found; a candidate docs fix once this PR lands.
- The Tracing Gantt Chart keeps the previous trace's viewport and selected span when its trace changes in place,
  for example after following a Trace Table link to the same dashboard, because `TracingGanttChart` initialises
  both with `useState` and the panel doesn't key it by trace. Independent of the query plugin; left for later.

**Next step:** screenshots into the PR description, mark it ready for review, then answer the review — starting
with the time-bound decision above.

### 2. OpenLIT — the ClickHouse schema contract with an existing Collector is undocumented

**Project:** [openlit/openlit](https://github.com/openlit/openlit)
**Status:** Hit during phase 1 step 2, 2026-09-09. Not yet filed.

OpenLIT's docs state that you "can reuse your existing infrastructure" and connect it to an
existing ClickHouse and OTel Collector. They do not state **which tables it expects**, that
it **creates and verifies the `otel_*` schema itself on startup**, or what happens when
those tables already exist because a Collector created them first.

We had to read `src/client/src/lib/platform/common.ts` to find the answer:

```ts
export const OTEL_TRACES_TABLE_NAME = "otel_traces";
export const OTEL_LOGS_TABLE_NAME = "otel_logs";
```

Having to read application source to learn the integration contract is the gap. Anyone
wiring OpenLIT to an existing pipeline needs exactly these two facts and cannot get them
from the documentation.

**What we did instead:** deployed the Collector first so its `clickhouseexporter` owned
schema creation, then pointed OpenLIT at the same database. It coexisted cleanly — OpenLIT
added 36 `openlit_*` tables and left `otel_traces` untouched.

**Why it still matters:** the deploy order is load-bearing and nothing says so. Deploy
OpenLIT first and it creates `otel_*` to its own definition, after which the Collector's
exporter must accept whatever it finds. Two orders, two possible schemas, no documentation
either way. Also worth noting: OpenLIT created five `otel_metrics_*` tables even though our
Collector has no metrics pipeline, so it provisions for a writer that may never arrive.

**Contribution type:** docs fix — a short "connecting to an existing OTel Collector"
section naming the expected tables, stating that OpenLIT creates them if absent, and
recommending an order. Low effort, high value, and a natural first contribution to this
project.

### 3. LiteLLM — `gen_ai.response.model` reports the gateway alias, not the model that served the request

**Project:** [BerriAI/litellm](https://github.com/BerriAI/litellm)
**Status:** Observed in phase 1 step 3, 2026-09-09, with `LITELLM_OTEL_V2=true` and
`LITELLM_OTEL_LEGACY_COMPAT=false`. Not yet filed.

A request routed through a gateway entry named `local`, which resolves to
`ollama_chat/qwen2.5:3b`, produced these span attributes:

```
gen_ai.request.model     local                      <- the alias
gen_ai.response.model    local                      <- the alias
litellm.provider.model   ollama_chat/qwen2.5:3b     <- the actual model, vendor-namespaced
```

Confirmed again on a second, unrelated provider (2026-09-09): a request to the `remote`
route reported `gen_ai.request.model = remote` and `gen_ai.response.model = remote`, with
the actual model `openrouter/nvidia/nemotron-3.5-lightning:free` again only under
`litellm.provider.model`. The behaviour is provider-independent — it is the gateway's
mapping, not an Ollama quirk — which makes it a cleaner bug report.

`gen_ai.request.model` carrying the alias is defensible — the caller did ask for `local`.
`gen_ai.response.model` is not. The OTel GenAI semantic conventions define it as the model
that *generated the response*, and no model called `local` exists. The real identity is
only available under a `litellm.*` key, which is precisely the vendor-specific vocabulary
that adopting the semconv is supposed to make unnecessary.

**Why this matters beyond tidiness, and why it belongs in this project:** one of the four
audit questions this lab exists to answer is *what did the agent do*, and "which model
processed this request" is part of that answer. A regulated enterprise reading only
standard GenAI attributes — the portable ones, the ones a vendor-neutral audit tool would
consume — gets the gateway's routing alias and cannot tell whether a request was served by
a local 3B model or a third-party frontier model. Those have materially different
compliance consequences. The information exists; it is just not in the field the standard
reserves for it.

**What we did instead:** nothing yet — recorded rather than worked around, since a
workaround here (reading `litellm.provider.model` in our queries) is exactly what would
make the gap invisible and permanent.

**Contribution type:** bug report, likely a small code change. Populate
`gen_ai.response.model` from the resolved provider model while leaving
`gen_ai.request.model` as the requested alias. Worth opening as an issue first to check
whether the current behaviour is deliberate.

### 4. OpenLIT SDK — `capture_message_content` defaults to True, against the semconv default

**Project:** [openlit/openlit](https://github.com/openlit/openlit) (Python SDK)
**Status:** Found while writing the workflow scaffold, phase 1 step 4, 2026-09-09. Not filed.

`openlit.init()` signature, `sdk/python/src/openlit/__init__.py`:

```python
def init(
    environment="default",
    application_name="default",
    ...
    capture_message_content=True,     # <- prompts and completions captured unless told otherwise
```

The OpenTelemetry GenAI semantic conventions specify the opposite default: content capture
is opt-in, with `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT` defaulting to
`no_content`. LiteLLM follows the spec and documents "prompts and responses are not
captured unless you explicitly opt in". OpenLIT's SDK inverts it.

**The failure mode is specific and quiet, and this lab is exactly the configuration that
produces it.** Route model calls through a LiteLLM gateway that is correctly configured for
`no_content`, then instrument the calling application with OpenLIT using its documented
one-line init. The gateway spans are clean. The SDK spans, emitted from inside the
application and sent to the same collector and the same ClickHouse, contain the full prompt
and completion. An operator who verified the gateway's posture — the component whose whole
job is being the policy boundary — would reasonably conclude content is not being stored,
and be wrong. Nothing warns them; both sets of spans land in `otel_traces` side by side.

For the regulated enterprises this project models, that is the difference between a control
and the appearance of one.

**What we did instead:** set `capture_message_content=False` explicitly in
`apps/workflow/src/workflow/telemetry.py`, with a comment explaining why the explicit
argument is load-bearing rather than decorative.

**Contribution type:** starts as an issue, because the fix is a judgement call rather than
an obvious patch. Options worth putting to the maintainers: flip the default to match the
spec (breaking, but in the safe direction); honour
`OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT` when it is set, which is
non-breaking and probably the right first step; or, at minimum, document the divergence
prominently. The interaction with a `no_content` gateway is worth spelling out either way —
it is not obvious, and the people most likely to hit it are the ones who care most.

### 5. GenAI semconv — nothing distinguishes a gateway's span for a model call from the client's span for the same call

**Projects:** [OTel GenAI semantic conventions](https://github.com/open-telemetry/semantic-conventions),
touching [openlit](https://github.com/openlit/openlit) and [litellm](https://github.com/BerriAI/litellm).
**Status:** Observed in phase 1 step 4, 2026-09-09. Not yet filed. Probably the most
practically consequential finding so far, because it produces wrong numbers silently.

One model call through this stack yields **two spans that both describe it**:

```
triage-workflow  chat local   gen_ai.usage.input_tokens=36  gen_ai.usage.output_tokens=2  gen_ai.usage.cost=0
litellm-gateway  chat local   gen_ai.usage.input_tokens=36  gen_ai.usage.output_tokens=2  litellm.cost.total=0
```

The OpenLIT SDK instruments the OpenAI client inside the application. LiteLLM instruments
the gateway. Neither is wrong, and both are doing what their documentation says. But the
obvious aggregation over a trace —

```sql
SELECT sum(toUInt64OrZero(v)) FROM otel_traces
ARRAY JOIN mapKeys(SpanAttributes) AS k, mapValues(SpanAttributes) AS v
WHERE TraceId = ... AND k = 'gen_ai.usage.input_tokens'
```

— returns **72 for a 36-token call**. Exactly double, with nothing in the data to indicate
it. Add a second gateway hop or a retry and the factor changes rather than staying a
predictable two, so it cannot even be divided out reliably.

The conventions give a span `gen_ai.operation.name = chat` in both places. There is no
attribute saying "this span is a relay of an operation another span already reports" —
no equivalent of a proxy or intermediary marker. A consumer cannot tell the difference
between two spans describing one call and two spans describing two calls, which is exactly
the distinction cost attribution depends on.

**Secondary observation, same root:** the two components report the same concept under
different keys — `gen_ai.usage.cost` from the SDK, `litellm.cost.total` from the gateway.
The semconv has no cost attribute at all, so every implementer invents one. For a project
whose phase 2 is spend attribution per agent, that is a gap worth raising in its own right.

**Why it matters here specifically:** phase 2's claim is per-agent cost and token
attribution for audit. Built naively on this data, every figure would be inflated by a
factor that depends on how many instrumented hops a call happened to traverse — and it
would look completely plausible.

**What we did instead:** nothing yet. Recorded before writing any query that works around
it, because the workaround (filtering by `ServiceName`, or picking the innermost span) is
local, fragile, and would hide the gap permanently.

**Contribution type:** issue against the semantic conventions proposing a way to mark a
span as an intermediary's view of an operation reported elsewhere. Possibly also an issue
against each of OpenLIT and LiteLLM once the convention question has an answer. This is the
kind of gap the brief predicted would show up at the multi-agent and gateway boundaries,
and it showed up at the very first one.

### 6. OpenLIT — the logs tab ships without its API routes, so the page cannot load at all

**Project:** [openlit/openlit](https://github.com/openlit/openlit)
**Status:** Hit 2026-09-09 on chart/app **1.24.0** (the current release). Not yet filed.

`/telemetry?tab=logs` fails immediately in the browser with:

```
Unexpected token '<', "<!DOCTYPE "... is not valid JSON
```

That message is the symptom of a `fetch()` receiving Next.js's 404 **HTML** page and
handing it to `response.json()`. The cause is that the client bundle calls three endpoints
that do not exist in the build:

```
/api/telemetry/logs                  <- the log list; this is the one that breaks the page
/api/telemetry/logs/config
/api/telemetry/logs/attribute-keys
```

Next.js's own routing table is unambiguous — `.next/server/app-paths-manifest.json`
contains, under `/api/telemetry/`, only:

```
/api/telemetry/metrics/route          /api/telemetry/metrics/[name]/route
/api/telemetry/metrics/attribute-keys/route
/api/telemetry/metrics/config/route   /api/telemetry/summary/[signal]/route
```

There is no `logs` segment, and `routes-manifest.json` declares no rewrites, so nothing
maps those paths onto another handler. The metrics tab has the full trio; the logs tab has
none of them. `/api/telemetry/summary/logs` *does* resolve — via the generic
`summary/[signal]` route — which is why the tab renders its summary strip before dying on
the list.

**This is not a configuration problem.** It is independent of ClickHouse, of the Collector,
of whether `otel_logs` exists or has rows, and of how the UI is exposed. The route is
absent from the shipped artefact, so every 1.24.0 deployment has it.

**What we did instead:** nothing — there is no workaround from outside the image. 1.24.0 is
the newest chart published, so there is no version to move to. The logs tab is unusable and
is documented as such rather than worked around.

**Contribution type:** bug report, with an unusually cheap repro — `find .next/server/app/api/telemetry -name route.js`
inside the released image shows the missing segment without deploying anything. Plausibly a
build/export omission (route group or `export const dynamic` missing on those handlers)
rather than deliberate removal, since the client half shipped.

### 7. OpenLIT SDK — an unguarded `ContextVar.reset()` in the LangChain handler leaks the LLM span, severing agent→model attribution

**Project:** [openlit/openlit](https://github.com/openlit/openlit)
**Status:** Hit during phase 1 step 6, 2026-09-10, on openlit 1.45.0. Not yet filed.

Every model call from an async LangGraph node produced a stack trace:

```
ERROR opentelemetry.context: Failed to detach context
ValueError: <Token var=<ContextVar name='current_context' ...>> was created in a different Context
```

Three separate things have to be true for that to reach an application's logs, and
they are all true here.

**One.** `openlit/instrumentation/langchain/__init__.py` attaches an OTel context in
`on_llm_start` and detaches it in `on_llm_end` and `on_llm_error` — the two
`otel_context.detach(ctx_token)` calls. Under an async graph those callbacks fire in
different asyncio Tasks. `contextvars` Tokens can only be reset in the Context that
created them, so the reset always raises.

**Two.** Both call sites wrap the detach in `except Exception: pass`, which looks like
the bug is already handled. It is not, and cannot be: `opentelemetry.context.detach()`
catches the `ValueError` *itself* and logs it at ERROR before returning normally. The
caller's `except` never sees anything. The suppression is real; the log line is emitted
regardless.

**Three — and this is what makes it a clean bug report rather than a design argument:**
OpenLIT already ships the correct fix and does not use it at these two sites.
`openlit.__helpers.safe_detach` detaches via `_RUNTIME_CONTEXT` precisely so a
cross-Context Token can be handled at DEBUG instead of ERROR, and takes an
`attaching_task` argument to short-circuit cross-Task exits before any detach is
attempted. Its docstring describes this exact failure mode in detail. Other
instrumentations use it. The LangChain handler does not.

**Consequence (as first written, 2026-09-10 — wrong, superseded below):** "harmless to
the data, expensive to trust", on the evidence of one run with 76 spans, correct-looking
parenting and no error spans. That run was never checked for spans whose parent does not
exist, and it had them. The ERROR line is not harmless: it is the visible symptom of a
context failure that, one statement later, drops spans. The original reasoning is kept
here rather than deleted because the mistake is instructive — "no error spans and the tree
looks right" is not evidence of a complete trace; a query for dangling `ParentSpanId`s is.

**What we did instead:** a `logging.Filter` on the `opentelemetry.context` logger that
drops only this message (`apps/workflow/src/workflow/telemetry.py`), rather than
silencing the logger, so a genuine context-management bug elsewhere still surfaces.

**Escalation, 2026-09-10 — the ERROR line was the visible half of a span leak.**

The log noise is not the damage. `on_llm_end` runs, in this order, inside one
`try` whose handler logs at **DEBUG**:

```python
try:
    ...
    if holder.token and isinstance(holder.token, tuple):
        fw_token, ctx_token = holder.token
        try:
            otel_context.detach(ctx_token)     # swallowed internally, logs ERROR
        except Exception:
            pass
        reset_framework_llm_active(fw_token)   # NOT protected
    self._end_span(run_id)                     # unreachable if the line above raises
except Exception as e:
    logger.debug("Error in on_llm_end: %s", e) # invisible at default levels
```

And `reset_framework_llm_active` (`openlit/__helpers.py:91`) is a bare reset:

```python
def reset_framework_llm_active(token):
    _framework_llm_span_active.reset(token)
```

Same cross-Task `ContextVar` problem as the detach, same guaranteed `ValueError` under an
async graph — but outside the inner `try`. So it raises, the outer handler logs at DEBUG,
and **`self._end_span(run_id)` never runs**. An OTel span is exported on `end()`; a span
that is never ended is never exported.

**Measured consequence in this lab:** 69 `POST` spans and 48 `mcp tools/call` spans on
`triage-workflow` have `ParentSpanId` values that exist in no row of `otel_traces`. The
missing rows are the LLM spans OpenLIT started and never ended. The practical effect is
that the chain

```
invoke_agent retriever  ->  [missing]  ->  POST  ->  litellm POST /v1/chat/completions  ->  chat local
```

has a hole exactly where the agent's identity meets the model call. Token counts survive
(they are on the gateway's span), and agent names survive (they are on the node span), but
**the two cannot be joined through the trace tree** — so "which agent spent these tokens",
the single most useful attribution question in an agent platform, is unanswerable from the
traces despite both halves being present.

This also means the ERROR line is worth more than it looks. It is emitted by the detach in
step one; the span leak happens silently in step two. Filtering the ERROR (as this lab
does) removes the only default-visible signal that cross-Task context failures are
occurring at all. The filter stays, because the message is genuinely not actionable — but
it is documented here as suppressing a symptom whose cause also drops data.

**Third consequence, 2026-09-10 — the ended span stays attached as current context.**

Guarding `reset_framework_llm_active` lets `_end_span` run, which fixes the export: in
the next run, spans with a non-existent parent went from 69 + 48 to **0**, and OpenLIT's
`chat <route>` spans appeared 1:1 with the gateway's. It does not fix the detach, and
cannot — a cross-Task Token genuinely cannot be reset. So the LLM span is ended but never
detached, and it stays attached to the OTel context of the Task that made the call.

Measured by logging `trace.get_current_span()` inside each LangGraph node after its model
call. All three nodes reported the same thing:

```
current span = 'chat remote'  recording=False
```

Not the node's `invoke_agent` span — OpenLIT's already-ended LLM span. Any attribute
written to "the current span" after a model call is written to a finished span and
silently discarded; any span started after a model call in that Task parents onto a dead
span. This is how a first attempt to record per-agent token usage on the node span
recorded nothing at all, with no error.

**What we did instead:** each node opens its own span with a tracer the workflow owns and
writes to that span object by reference, never via `get_current_span()`
(`apps/workflow/src/workflow/triage_graph.py`, `_Usage.stamp`). The guard on
`reset_framework_llm_active` is applied before `openlit.init()`, because
`_create_callback_handler_class()` closes over the helper at init time
(`apps/workflow/src/workflow/telemetry.py`).

**Contribution type:** code change, still small, now two-part:

1. Route the two `otel_context.detach(ctx_token)` calls through the existing
   `safe_detach`, passing the Task captured at attach time.
2. Guard `reset_framework_llm_active` — either catch `ValueError` in the helper (matching
   what `safe_detach` already does for the OTel context) or move `self._end_span(run_id)`
   into a `finally`, so ending the span cannot be skipped by a context-teardown failure.
   The second is the more robust shape regardless: span closure should not depend on
   contextvar bookkeeping succeeding.

The same unguarded pattern appears in `instrumentation/litellm/litellm.py:156,176` and
`instrumentation/strands/processor.py:177`, so the fix is likely not LangChain-specific.

### 8. OpenLIT — the telemetry page reads pre-semconv usage attribute names, so cost and tokens read zero

**Project:** [openlit/openlit](https://github.com/openlit/openlit)
**Status:** Found while checking the UI's filter controls, 2026-09-10, on chart 1.24.0. Not yet filed.

The telemetry page's trace summary aggregates usage and cost directly in SQL
(`.next/server/app/api/telemetry/summary/[signal]/route.js`):

```sql
CAST(SUM(toFloat64OrZero(SpanAttributes['gen_ai.usage.cost']))  AS FLOAT)   AS cost,
CAST(SUM(toInt64OrZero(SpanAttributes['gen_ai.usage.total_tokens'])) AS INTEGER) AS tokens
```

Neither attribute is what a current-semconv producer emits. Across 24 hours of this
lab's traces:

| attribute | spans |
| :- | -: |
| `gen_ai.usage.input_tokens` | 100 |
| `gen_ai.usage.output_tokens` | 100 |
| `litellm.cost.total` | 97 |
| `gen_ai.usage.total_tokens` | **0** |
| `gen_ai.usage.cost` | 3 |

The GenAI semantic conventions define `gen_ai.usage.input_tokens` and
`gen_ai.usage.output_tokens`. There is no `total_tokens` — it was a Traceloop-era name —
and there is no `gen_ai.usage.cost` at all; cost is not in the semconv, and LiteLLM
publishes it under its own `litellm.cost.total`. The 3 `gen_ai.usage.cost` spans are from
OpenLIT's *own* SDK instrumenting the workflow process, so the UI agrees with its SDK and
with nothing else.

**What makes this sharp rather than a version skew:** the condition is *caused* by
following the spec. This lab sets `OTEL_SEMCONV_STABILITY_OPT_IN=gen_ai_latest_experimental`
and `LITELLM_OTEL_LEGACY_COMPAT=false` on the gateway — deliberately, and documented in
`deploy/50-litellm/litellm.yaml`, to avoid two vocabularies for the same data in
ClickHouse. That choice is what makes OpenLIT's panels read zero. A user who left the
legacy names on would see numbers; a user who opted into the current conventions sees
zeros, with no indication that the attribute name is the reason.

**Consequence:** the cost and token columns on the telemetry page are silently zero for
any semconv-compliant producer. Same failure shape as item 6 and as the empty `otel_logs`
table: a populated page showing 0 reads as "no spend in this window" and gets believed.

**What we did instead:** nothing in the UI — there is no knob. Token and cost figures for
this lab come from ClickHouse directly, against `gen_ai.usage.input_tokens` /
`output_tokens` / `litellm.cost.total`.

**Contribution type:** bug report, plausibly a small code change — read the semconv names
with the legacy ones as fallback (`COALESCE`-style, or
`input_tokens + output_tokens` when `total_tokens` is absent), and take cost from a
provider-namespaced attribute when `gen_ai.usage.cost` is missing.

## Watch list

Carried from the project brief. These are suspected gaps to verify, not findings:

| Project | Suspected gap | Verify by |
| :- | :- | :- |
| LangGraph | OpenTelemetry instrumentation known to be incomplete upstream | Phase 1, step 7 |
| OpenLIT | Instrumentation coverage — which spans we still hand-roll | Phase 1, step 7 (schema-contract gap already promoted to item 2) |
| OTel GenAI semconv | Cannot express multi-agent handoff semantics | Phase 1, step 7 |
| LiteLLM | GenAI semconv coverage where it meets MCP tool calls | Phase 1, step 8 (model-identity gap already promoted to item 3) |
| ~~Perses~~ | ~~ClickHouse trace-query SDK missing~~ | **Verified — promoted to Open, item 1** |
| OpenLIT | Whether other tabs share the logs tab's missing-route defect | Any tab that renders empty or throws a JSON parse error |

## Filed

| Item | Upstream | Kind | Date |
| :- | :- | :- | :- |
| 1. Perses — ClickHouse trace query | [perses/perses#4202](https://github.com/perses/perses/issues/4202) (existing issue, commented) · [perses/plugins#813](https://github.com/perses/plugins/pull/813) | Code change, PR (draft) | 2026-09-12 |
