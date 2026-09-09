# deploy/

Numbered by deployment order, because the order is load-bearing rather than cosmetic —
see step 2 in LEARNINGS.md for what happens if you reverse 20 and 30.

| Dir | What | How |
| :- | :- | :- |
| `05-minio/` | MinIO object storage — a **VM on the Proxmox host**, not in the cluster | `make minio` |
| `00-namespace/` | `agent-obs-platform` and `agent-obs-app` | `make namespaces` |
| `10-clickhouse/` | ClickHouse hot store, plain StatefulSet | `make clickhouse` |
| `20-otel-collector/` | OTel Collector (contrib) — **owns the write path** | `make collector` |
| `30-openlit/` | OpenLIT UI over the same ClickHouse — reads only | `make openlit` |
| `40-ollama/` | Self-hosted model backend | `make ollama` |
| `45-litellm-db/` | PostgreSQL for the gateway's identity tables (CNPG) | `make litellm-db` |
| `50-litellm/` | LiteLLM gateway — every model call goes through it | `make litellm` |
| `60-postgres/` | PostgreSQL for the workflow's own state (CNPG) | `make postgres` |
| `70-workflow/` | The LangGraph workflow probe | `make workflow-probe` |
| `80-mcp/` | Three MCP tool servers over streamable HTTP | `make mcp` |

`05-minio/` is numbered before `00-namespace/` because it is not in the cluster at all —
it is the one dependency that has to exist before Kubernetes is even relevant.

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

## Reaching the LiteLLM UI

Same `platform` Gateway. Add a hosts entry for `litellm.kube.local` alongside the OpenLIT
one, then log in with `LITELLM_UI_USERNAME` / `LITELLM_UI_PASSWORD` from `.env` — not the
master key, which is deliberately no longer a UI password.

The UI needs `45-litellm-db/` deployed. Without it the proxy serves model traffic normally
and answers every login with `Authentication Error, Not connected to DB!`.
