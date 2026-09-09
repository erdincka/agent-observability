# CONTRIBUTIONS

Upstream gaps hit while building this lab, logged the moment we hit them — not
reconstructed afterwards, because by then the workaround looks like the design.

For each entry: which project, what is missing or broken, what we did instead, and what
kind of contribution it looks like (docs fix / example / bug report / code change).

## Open

### 1. Perses — ClickHouse datasource has no TraceQuery plugin

**Project:** [perses/plugins](https://github.com/perses/plugins)
**Status:** Verified at source level, 2026-09-09. Not yet filed.

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

**Next step:** open an issue against perses/plugins describing the gap and asking whether
a ClickHouse TraceQuery is wanted and what trace schema it should assume (the OTel
`clickhouseexporter` `otel_traces` layout being the obvious candidate), before writing code.

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

## Watch list

Carried from the project brief. These are suspected gaps to verify, not findings:

| Project | Suspected gap | Verify by |
| :- | :- | :- |
| LangGraph | OpenTelemetry instrumentation known to be incomplete upstream | Phase 1, step 7 |
| OpenLIT | Instrumentation coverage — which spans we still hand-roll | Phase 1, step 7 (schema-contract gap already promoted to item 2) |
| OTel GenAI semconv | Cannot express multi-agent handoff semantics | Phase 1, step 7 |
| LiteLLM | GenAI semconv coverage where it meets MCP tool calls | Phase 1, step 8 (model-identity gap already promoted to item 3) |
| ~~Perses~~ | ~~ClickHouse trace-query SDK missing~~ | **Verified — promoted to Open, item 1** |

## Filed

_Nothing filed yet._
