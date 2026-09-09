# CONTRIBUTIONS

Upstream gaps hit while building this lab, logged the moment we hit them — not
reconstructed afterwards, because by then the workaround looks like the design.

For each entry: which project, what is missing or broken, what we did instead, and what
kind of contribution it looks like (docs fix / example / bug report / code change).

## Open

_None logged yet — nothing deployed._

## Watch list

Carried from the project brief. These are suspected gaps to verify, not findings:

| Project | Suspected gap | Verify by |
| :- | :- | :- |
| LangGraph | OpenTelemetry instrumentation known to be incomplete upstream | Phase 1, step 7 |
| OpenLIT | Instrumentation coverage — which spans we still hand-roll | Phase 1, step 7 |
| OTel GenAI semconv | Cannot express multi-agent handoff semantics | Phase 1, step 7 |
| LiteLLM | GenAI semconv coverage where it meets MCP tool calls | Phase 1, step 8 |
| Perses | ClickHouse plugin SDKs cover datasource, log query and time-series query; no trace-query SDK visible. If traces are unsupported this is the best contribution target in the project. | **Verify early — before phase 3** |

## Filed

_Nothing filed yet._
