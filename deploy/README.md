# deploy/

Numbered by deployment order, because the order is load-bearing rather than cosmetic —
see step 2 in LEARNINGS.md for what happens if you reverse 20 and 30.

| Dir | What | How |
| :- | :- | :- |
| `00-namespace/` | `agent-obs-platform` and `agent-obs-app` | `make namespaces` |
| `10-clickhouse/` | ClickHouse hot store, plain StatefulSet | `make clickhouse` |
| `20-otel-collector/` | OTel Collector (contrib) — **owns the write path** | `make collector` |
| `30-openlit/` | OpenLIT UI over the same ClickHouse — reads only | `make openlit` |

Credentials come from a gitignored `.env` at the repo root, rendered into Kubernetes
Secrets by `make secrets`. Copy `.env.example` to `.env` first. No password appears in any
file in this directory.

## Verifying the pipeline

```bash
make smoke-trace
```

Hand-builds one OTLP span, POSTs it from a throwaway in-cluster pod, and polls ClickHouse
for the trace ID. No application, SDK or instrumentation library involved — so when a trace
goes missing later, this answers "pipeline or application?" in about ten seconds.

## Reaching the OpenLIT UI

The `platform` Gateway serves `*.kube.local` at `10.1.1.241`. Either add a hosts entry:

```
10.1.1.241  openlit.kube.local
```

or port-forward: `kubectl port-forward -n agent-obs-platform svc/openlit 3000:3000`.
