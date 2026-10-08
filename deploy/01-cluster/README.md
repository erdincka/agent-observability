# 01-cluster/

The single-machine path: one VM on a Proxmox host, one k3s node, and the three
things the manifests under `deploy/` assume are already in the cluster.

```bash
make k3s-vm             # clone the template, install k3s, fetch the kubeconfig
make cluster-prereqs    # Envoy Gateway, CloudNativePG, kube-prometheus-stack
make cluster            # both
```

Numbered `01` because it comes after the MinIO VM (`05-minio/` is outside the
cluster and is numbered for the deployment order, not the directory order) and
before anything that needs a cluster. On a cluster that already has these
components (the original lab did), skip this directory and set `KUBECONFIG`,
`REGISTRY`, `GATEWAY_IP` and `K8S_API_IP` in `.env` to point at it.

## What `.env` has to say

| Variable | Meaning |
| :- | :- |
| `PVE_HOST`, `PVE_TEMPLATE_VMID`, `PVE_STORAGE` | The hypervisor, a cloud-init template to clone (Debian or Ubuntu, with `qemu-guest-agent`), the pool to clone onto |
| `VM_GW`, `VM_DNS`, `VM_USER`, `VM_SSHKEY` | Shared by the MinIO and k3s VMs; each has `MINIO_VM_*` / `K3S_VM_*` overrides |
| `K3S_VMID`, `K3S_VM_NAME`, `K3S_VM_IP`, `K3S_VM_CORES`, `K3S_VM_MEMORY`, `K3S_VM_DISK_GB`, `K3S_VERSION` | The VM. Size the disk for the whole lab: `local-path` cannot grow a volume |
| `REGISTRY` | The registry the node pulls from, plain HTTP. Written into `/etc/rancher/k3s/registries.yaml` |
| `KUBECONFIG` | Where `make k3s-vm` writes the kubeconfig, and what every `kubectl`/`helm` in the Makefile uses |
| `GATEWAY_IP` | The address the `platform` Gateway answers on. On a single node, the VM's address (k3s ServiceLB) |
| `GATEWAY_DOMAIN` | The domain the Gateway listens on (`*.<domain>`) and the UIs are routed under; `kube.local` by default, one per cluster. Point wildcard DNS at `GATEWAY_IP` |
| `K8S_API_IP` | Where the API server is reached from a pod after NAT: the control-plane node. Used by the mcp-ops NetworkPolicy |

## What `cluster-prereqs` installs, and why each

| Component | Version | Referenced by |
| :- | :- | :- |
| Envoy Gateway | v1.9.2, GatewayClass `envoy`, Gateway `platform`/`web` on `*.<GATEWAY_DOMAIN>` | every `httproute.yaml` (`make routes` re-applies them) |
| CloudNativePG | chart 0.29.0, operator 1.30.0 | the three `Cluster` manifests |
| kube-prometheus-stack | chart 91.9.0, Grafana and Alertmanager off | `mcp-metrics` (`PROMETHEUS_URL`), the `mcp-metrics-egress` NetworkPolicy |

Not installed: cert-manager (no TLS anywhere in the lab) and MetalLB (ServiceLB is
enough for one node). Traefik, which k3s ships, is disabled at install so the
Gateway can hold port 80.

## The VM

Cloned in full from the template, static address via cloud-init, `qemu-guest-agent`
on, boots with the host. k3s is pinned (`K3S_VERSION`) and installed with
`--disable traefik`; NetworkPolicy enforcement stays on because chapter 7 depends on
it. `local-path` is the default StorageClass, as on the original lab, with the same
consequence: volumes cannot grow after the fact.

Single node means single everything: the control plane and every workload share
twelve vCPUs and 32 GiB by default. Ollama's node affinity is a preference rather
than a requirement for this reason (`deploy/40-ollama/ollama.yaml`).
