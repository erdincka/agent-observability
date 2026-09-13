# 1. One span, end to end

**Question it answers:** does the pipeline work, independently of any application? And
what is the contract between the Collector and the tools that read what it writes?
**Status:** built.
**Tools:** OTel Collector, ClickHouse, OpenLIT.

## Run

```bash
make step1        # namespaces, secrets, ClickHouse, Collector, then the smoke trace
make step2        # OpenLIT, reading the same ClickHouse
```

`make smoke-trace` on its own re-runs just the proof.

## Look

The smoke test hand-writes one OTLP/JSON span, posts it from a throwaway pod inside the
cluster, and polls ClickHouse for the trace id it generated. No SDK, no instrumentation
library, no application. Then:

```bash
make ch-query Q="SELECT SpanName, ServiceName, Duration FROM otel_traces ORDER BY Timestamp DESC LIMIT 5"
make ch-query Q="SHOW TABLES"
```

## What you should see

The span is in `otel_traces` within about five seconds. `SHOW TABLES` lists the four
tables the exporter created, `otel_logs`, `otel_traces`, `otel_traces_trace_id_ts` and its
materialised view, plus the `openlit_*` tables OpenLIT added alongside them without touching
the exporter's schema.

## What it means

**A pipeline probe with no application in it is the most valuable ten seconds in the
repo.** Every later "the trace is missing" question splits into "pipeline or
application?", and this answers it. It has been used to settle that question more than
once.

**The table schema is a contract, and deploy order decides who writes it.** OpenLIT does
not merely read `otel_traces`; it creates and verifies that schema on startup. Because the
Collector went first, the exporter's definition won. Reverse the order and OpenLIT's
definition wins, and nothing in either project's documentation says which is intended.

**`SpanAttributes` is a `Map`, not columns.** Every GenAI attribute lands as a map key.
That is why chapter 8's redaction is map manipulation rather than column dropping, and
why the queries in this guide look the way they do.

## Where it breaks

- OpenLIT's integration contract with an existing Collector is undocumented. You learn the
  expected table names by reading its source. CONTRIBUTIONS item 2.
- OpenLIT provisions tables for writers that may never arrive, so the presence of a table
  proves nothing about whether anything writes to it. `otel_logs` had zero rows for the
  whole of phase 1 while a working logs pipeline sat in front of it.
- The chart's default receivers must be explicitly nulled, not omitted. Helm merges
  defaults into the supplied config, so leaving `jaeger` out leaves it listening.

## In an enterprise

The Collector being the only writer is not tidiness. It is the precondition for every
governance control in this guide: redaction, routing and retention are only enforceable
if there is exactly one path into storage. A store with two writers has no control point,
and an SDK that can export directly to the store is a bypass waiting to be configured.

Listeners you did not ask for are an audit question. "Why is Jaeger on 14250?" has no
good answer when the honest one is "the chart default".

## Read more

- LEARNINGS.md: *Step 1* and *Step 2* (2026-09-09), *The OpenLIT logs tab is broken
  upstream* (2026-09-09).
- `scripts/smoke-trace.sh`, `deploy/20-otel-collector/values.yaml`.
