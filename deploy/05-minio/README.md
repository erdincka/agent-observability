# 05-minio/

Object storage for the lab, running as a **standalone VM on the Proxmox host** rather
than in Kubernetes.

```bash
make minio          # vm + buckets + secret + verify
make minio-status   # is it up, how full is the disk
```

## Why it is outside the cluster

MinIO is meant to be the durable thing the cluster leans on. A store scheduled *by* the
cluster it backs cannot serve that role — rebuild k3s and it takes its own backups with
it. Putting it on the hypervisor makes the dependency point one way.

It is also the one component here whose lifetime should exceed the project's.

## What this is, and what it is not

**It is S3-compatible object storage.** It is *not* a PersistentVolume backend: nothing
here lets a pod claim a `ReadWriteOnce` filesystem from MinIO. `local-path` remains the
only StorageClass and PVCs are unaffected by this deployment. Making MinIO back real PVCs
needs a further layer (a CSI driver, or JuiceFS with its own metadata engine) and is not
installed.

What it *is* good for, and the reason the buckets below exist:

| Bucket | Intended consumer |
| :- | :- |
| `otel-archive` | Collector cold tier — telemetry aged out of ClickHouse |
| `clickhouse-cold` | ClickHouse tiered storage / backups |
| `cnpg-backups` | CloudNativePG backups for `workflow-db` and `litellm-db` |
| `workflow-artifacts` | Workload artefacts |

None of those consumers are wired up yet — this step delivers the store and proves the
cluster can reach it. Wiring each one is its own change.

## Shape

Every value below comes from `.env` (`PVE_*`, `MINIO_VM_*`); these are the original
lab's, kept as the worked example.

| | |
| :- | :- |
| VM | `MINIO_VMID` / `minio`, 4 vCPU, 8 GiB, full clone of template `PVE_TEMPLATE_VMID` |
| Address | `MINIO_VM_IP` — static, via cloud-init, outside any LoadBalancer pool |
| Boot disk | 32 GiB on `PVE_STORAGE` |
| Data disk | `MINIO_VM_DATA_GB` on `PVE_STORAGE`, bare XFS at `/mnt/minio/disk1` |
| S3 API | `MINIO_ENDPOINT`, i.e. `http://<MINIO_VM_IP>:9000` |
| Console | `http://<MINIO_VM_IP>:9001` — log in with `MINIO_ROOT_*` from `.env` |
| Version | `RELEASE.2025-09-07T16-13-09Z`, pinned and checksum-verified |

The template can be any cloud-init image with `qemu-guest-agent`: Ubuntu 24.04 or
Debian 13 have both been used. The installer adds `xfsprogs` and `curl` itself if the
image lacks them (Debian's does).

Single-node single-drive, so **no erasure coding**. Deliberate: the ZFS pool underneath is
a three-disk stripe with no redundancy, so parity across four zvols on that pool would
protect against nothing a real disk failure would do. Bucket versioning is enabled
everywhere, which is the protection that does apply here — it covers overwrite and
accidental delete, which is what actually happens in a lab.

## Credentials

Two, and the distinction is the point:

- **`MINIO_ROOT_*`** builds the VM and mints the second credential. It never enters
  Kubernetes.
- **`MINIO_K8S_*`** is a separate MinIO user whose policy covers exactly `MINIO_BUCKETS`
  and nothing else. `make minio-secret` publishes it as the Secret `minio-auth` in both
  namespaces, with the standard `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` /
  `S3_ENDPOINT` keys.

`make minio-verify` asserts both that an object round-trips **and** that a bucket outside
the policy is refused. It runs the lab's own `mc` image (`apps/mc/Dockerfile`, built by
`make mc-image` from the same pinned GitHub release as the VM's binary): Docker Hub stopped
serving `minio/mc` in 2026-10, together with the binaries on dl.min.io. The second assertion is the one worth having: without it an
over-broad credential passes exactly as well as a correct one.

## No TLS

Plain HTTP on a private VLAN, consistent with the existing lab registry. cert-manager
issues certificates inside the cluster and MinIO is outside it, so TLS here means a
different issuance path — a phase 2 item, not an oversight.
