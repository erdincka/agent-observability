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
