# This lab's environment

The guide is written so that the *findings* transfer to any Kubernetes cluster with the
same components. The *commands* assume one of two environments, and everything that
differs between them lives in `.env`: nothing about a hypervisor, a registry or a cluster
address is baked into the Makefile or the scripts. This page is the honest list of what
is assumed, so that a reader can map each item onto their own environment.

**Two shapes are supported.** The original lab, a three-node k3s cluster that already had
a Gateway, CloudNativePG and Prometheus from other work; and the single-machine path,
one VM on a Proxmox host that `make cluster` builds and equips from nothing
([deploy/01-cluster/](../deploy/01-cluster/README.md)). The second is what a reader
without a cluster should use. Both were built with this repository; the single-VM path
on 2026-10-05.

## Cluster

| Item | Original lab | Single-VM path | Where it is set |
| :- | :- | :- | :- |
| Kubernetes | k3s v1.36, three amd64 nodes | k3s v1.36.5, one VM: 12 vCPU, 32 GiB, 160 GiB | `K3S_*` |
| StorageClass | `local-path`, `WaitForFirstConsumer`, `Delete`, no expansion | same | — |
| CloudNativePG operator | 1.30.0, pre-installed | 1.30.0, `make cluster-prereqs` | — |
| Prometheus | kube-prometheus-stack in `observability`, pre-existing | kube-prometheus-stack 91.9.0, Grafana and Alertmanager off, `make cluster-prereqs` | — |
| Envoy Gateway | Gateway `platform` at a MetalLB address, `*.kube.local` | Gateway `platform` at the VM's address (k3s ServiceLB), `*.zbook.local` | `GATEWAY_IP`, `GATEWAY_DOMAIN` |
| Container registry | in-cluster, plain HTTP | a Docker host on the LAN, plain HTTP | `REGISTRY` |
| Build host | Docker context `pve`, amd64, over SSH | Docker context `zbook`, amd64, over SSH | `DOCKER_BUILD_CONTEXT` |
| kubeconfig | the workstation's default | `./kubeconfig-<name>`, written by `make k3s-vm` | `KUBECONFIG` |

The Gateway controller is only used to expose the UIs; `kubectl port-forward` is the
alternative. The build host must list `REGISTRY` under `insecure-registries` in its
`daemon.json`; the k3s installer tells containerd the same thing.

## Outside the cluster

| Item | Value here | Portable? |
| :- | :- | :- |
| MinIO | A VM on the Proxmox host, built by `make minio-vm` from `MINIO_VM_*`; Ubuntu 24.04 or Debian 13 template | Any S3 endpoint with four buckets. Not needed until chapter 8 |
| Ollama | In-cluster, CPU only, `qwen2.5:3b` | Any Ollama; set `OLLAMA_BASE_URL` |
| External model route | OpenRouter, opt-in via `.env` | Any OpenAI-compatible endpoint |

## Workstation

`kubectl`, `helm`, `uv`, `docker`, `python3`, `ssh`. The workstation here is arm64 macOS,
which is why images are built remotely.

## Building it here

```bash
cp .env.example .env    # then fill in the "Where this runs" section
make cluster            # single-VM path only: the k3s VM and its prerequisites
make minio              # the MinIO VM, buckets, in-cluster credential, round-trip
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

`make cluster` before `make minio`: the MinIO VM itself needs no cluster, but `make minio`
also publishes the credential into the cluster and round-trips an object from a pod, so it
wants one to exist. `make help` lists every target. [deploy/README.md](../deploy/README.md) has the
deployment order and why it matters.

## Reaching the UIs

Four UIs, all through the `platform` Gateway at `GATEWAY_IP`, all under `*.GATEWAY_DOMAIN`
(`kube.local` on the original lab, `zbook.local` on the single-VM one; one domain per cluster so
two labs on one network do not collide):

| UI | Hostname | What it shows | Login |
| :- | :- | :- | :- |
| OpenLIT | `openlit.<domain>` | per-trace GenAI view (chapters 3 to 5) | its own admin |
| LiteLLM | `litellm.<domain>` | keys, teams, spend, guardrails (chapters 6 and 7) | `LITELLM_UI_USERNAME` / `LITELLM_UI_PASSWORD` from `.env` |
| Perses | `perses.<domain>` | the four dashboards and the trace view (chapter 10) | none |
| MLflow | `mlflow.<domain>` | the evaluation runs (chapter 11) | none |

Add a wildcard DNS record for `*.<domain>` pointing at `GATEWAY_IP` (or one hosts entry per
UI), or `kubectl port-forward` the Services
(`openlit:3000`, `litellm:4000`, `perses:8080`, `mlflow:80`, all in `agent-obs-platform`).

## Reproducibility, as it stands

- Python dependencies install `--frozen` from `apps/*/uv.lock`; base images are pinned by
  digest; third-party images by version.
- An image tag is the last commit that touched that image's inputs. Uncommitted inputs
  produce a `-dirty` tag that is rebuilt and pulled every time.
- `make drift` diffs every manifest and every Helm value against the cluster.
- Teardown and rebuild onto the same cluster: done 2026-09-23. Build onto an empty
  machine: done 2026-10-05, on the single-VM path.
