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

## Watch list

Carried from the project brief. These are suspected gaps to verify, not findings:

| Project | Suspected gap | Verify by |
| :- | :- | :- |
| LangGraph | OpenTelemetry instrumentation known to be incomplete upstream | Phase 1, step 7 |
| OpenLIT | Instrumentation coverage — which spans we still hand-roll | Phase 1, step 7 |
| OTel GenAI semconv | Cannot express multi-agent handoff semantics | Phase 1, step 7 |
| LiteLLM | GenAI semconv coverage where it meets MCP tool calls | Phase 1, step 8 |
| ~~Perses~~ | ~~ClickHouse trace-query SDK missing~~ | **Verified — promoted to Open, item 1** |

## Filed

_Nothing filed yet._
