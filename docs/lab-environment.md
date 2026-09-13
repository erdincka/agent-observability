# This lab's environment

The guide is written so that the *findings* transfer to any Kubernetes cluster with the
same components. The *commands* currently assume the author's lab. This page is the
honest list of what they assume, so that a reader can map each item onto their own
environment or wait for the single-machine path.

**A single-machine path is the next piece of infrastructure work**: one node, no gateway
controller, no private registry, no hypervisor. Until it exists, expect to adapt the
items marked *lab-specific*.

## Cluster

| Item | Value here | Portable? |
| :- | :- | :- |
| Kubernetes | k3s v1.36, three amd64 nodes | Any cluster with a default StorageClass |
| StorageClass | `local-path`, `WaitForFirstConsumer`, `Delete`, no expansion | Any. Size ClickHouse generously; volumes here cannot grow |
| CloudNativePG operator | 1.30.0, pre-installed | Install it, or replace the two `Cluster` manifests with any PostgreSQL |
| Prometheus | kube-prometheus-stack in `observability`, pre-existing | The metrics tool server queries it. Any Prometheus URL works |
| Envoy Gateway | Gateway `platform` at 10.1.1.241, `*.kube.local` | *Lab-specific.* Only used to expose the two UIs; `kubectl port-forward` is the alternative |
| Container registry | 10.1.1.240:5000, plain HTTP | *Lab-specific.* Any registry the nodes can pull from |
| Build host | Docker context `pve`, amd64, over SSH | *Lab-specific.* Any amd64 Docker host, or a multi-arch build |
| Tempo, Grafana | Present from other work, unused | Irrelevant, but note the shared OTLP ports |

## Outside the cluster

| Item | Value here | Portable? |
| :- | :- | :- |
| MinIO | VM 1040 on a Proxmox host, 10.1.1.20, 500 GiB XFS | *Lab-specific.* Any S3 endpoint with four buckets. Not needed until chapter 8 |
| Ollama | In-cluster, CPU only, `qwen2.5:3b` | Any Ollama; set `OLLAMA_BASE_URL` |
| External model route | OpenRouter, opt-in via `.env` | Any OpenAI-compatible endpoint |

## Workstation

`kubectl`, `helm`, `uv`, `docker`, `python3`, `ssh`. The workstation here is arm64 macOS,
which is why images are built remotely.

## Building it here

```bash
cp .env.example .env
make minio              # optional, and only on this lab's hypervisor
make step1              # namespaces, secrets, ClickHouse, Collector, smoke trace
make step2              # OpenLIT
make step3              # Ollama, model pull, gateway and its database
make postgres           # workflow state
make step5              # MCP image, tool servers, probe
make workflow-image
make workflow-probe
make workflow-triage    # INCIDENT= ROUTE=local|remote
make litellm-keys && make netpol           # chapters 6 and 7
make ch-restricted-user && make retention  # chapter 8
make perses-image && make perses           # chapter 10
make mlflow && make evaluate               # chapter 11
```

`make help` lists every target. [deploy/README.md](../deploy/README.md) has the
deployment order and why it matters.

## Reaching the UIs

Four UIs, all through the `platform` Gateway at 10.1.1.241, all `*.kube.local`:

| UI | Hostname | What it shows | Login |
| :- | :- | :- | :- |
| OpenLIT | `openlit.kube.local` | per-trace GenAI view (chapters 3 to 5) | its own admin |
| LiteLLM | `litellm.kube.local` | keys, teams, spend, guardrails (chapters 6 and 7) | `LITELLM_UI_USERNAME` / `LITELLM_UI_PASSWORD` from `.env` |
| Perses | `perses.kube.local` | the four dashboards and the trace view (chapter 10) | none |
| MLflow | `mlflow.kube.local` | the evaluation runs (chapter 11) | none |

Add hosts entries pointing at the gateway, or `kubectl port-forward` the Services
(`openlit:3000`, `litellm:4000`, `perses:8080`, `mlflow:80`, all in `agent-obs-platform`).

## Reproducibility, as it stands

- Python dependencies install `--frozen` from `apps/*/uv.lock`; base images are pinned by
  digest; third-party images by version.
- An image tag is the last commit that touched that image's inputs. Uncommitted inputs
  produce a `-dirty` tag that is rebuilt and pulled every time.
- `make drift` diffs every manifest and every Helm value against the cluster.
- Not yet done: a teardown and rebuild onto an empty cluster.
