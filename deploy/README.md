# deploy/

Numbered by deployment order, because the order is load-bearing rather than cosmetic —
see step 2 in LEARNINGS.md for what happens if you reverse 20 and 30.

| Dir | What | How |
| :- | :- | :- |
| `05-minio/` | MinIO object storage — a **VM on the Proxmox host**, not in the cluster | `make minio` |
| `01-cluster/` | The single-VM path: a k3s VM, and the Gateway, CloudNativePG and Prometheus the manifests assume | `make cluster` |
| `00-namespace/` | `agent-obs-platform` and `agent-obs-app` | `make namespaces` |
| `10-clickhouse/` | ClickHouse hot store, plain StatefulSet | `make clickhouse` |
| `20-otel-collector/` | OTel Collector (contrib) — **owns the write path** | `make collector` |
| `30-openlit/` | OpenLIT UI over the same ClickHouse — reads only | `make openlit` |
| `40-ollama/` | Self-hosted model backend | `make ollama` |
| `45-litellm-db/` | PostgreSQL for the gateway's identity tables (CNPG) | `make litellm-db` |
| `50-litellm/` | LiteLLM gateway — every model call goes through it | `make litellm` |
| `60-postgres/` | PostgreSQL for the workflow's own state (CNPG) | `make postgres` |
| `70-workflow/` | The LangGraph workflow as one-shot Jobs: the plumbing probe, and the triage graph (templated by make — applying `triage-job.yaml` directly leaves `__INCIDENT__` unfilled) | `make workflow-probe`, `make workflow-triage INCIDENT= ROUTE=` |
| `80-mcp/` | Four MCP tool servers over streamable HTTP, the role→tool policy | `make mcp` |
| `85-netpol/` | NetworkPolicies: governed pods may reach only the gateway, the tool servers, DNS, their database and the Collector | `make netpol` |
| `90-perses/` | Perses with the ClickHouse trace-query plugin; dashboards as JSON | `make perses-image`, `make perses` |
| `95-mlflow/` | MLflow, the evaluation loop, on CloudNativePG and MinIO | `make mlflow` |

`05-minio/` is numbered before `00-namespace/` because it is not in the cluster at all —
it is the one dependency that has to exist before Kubernetes is even relevant. `01-cluster/`
is the cluster itself, for a reader who does not have one; on a cluster that already has
its three prerequisites it is skipped.

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

The `platform` Gateway serves `*.kube.local` at `GATEWAY_IP` (from `.env`). Either add a
hosts entry:

```
<GATEWAY_IP>  openlit.kube.local
```

or port-forward: `kubectl port-forward -n agent-obs-platform svc/openlit 3000:3000`.

## Reaching the LiteLLM UI

Same `platform` Gateway. Add a hosts entry for `litellm.kube.local` alongside the OpenLIT
one, then log in with `LITELLM_UI_USERNAME` / `LITELLM_UI_PASSWORD` from `.env` — not the
master key, which is deliberately no longer a UI password.

The UI needs `45-litellm-db/` deployed. Without it the proxy serves model traffic normally
and answers every login with `Authentication Error, Not connected to DB!`.
