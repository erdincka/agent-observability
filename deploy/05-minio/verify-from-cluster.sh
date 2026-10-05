#!/usr/bin/env bash
# Proves, from inside the cluster, that the object store is actually usable —
# and that the credential we handed the cluster is actually scoped.
#
# Same reasoning as scripts/smoke-trace.sh: when a consumer fails later, this
# answers "storage or consumer?" in about twenty seconds, without an application
# or an SDK in the way. It runs a throwaway `mc` pod, so it also proves the path
# a real workload would take — pod network out of the CNI, off the node, to a
# host that is not part of the cluster.
#
# Two assertions, and the second is the one worth having:
#   1. an object round-trips through a bucket the policy allows
#   2. a bucket the policy does NOT list is refused
# Without (2) an over-broad credential passes exactly as well as a correct one.
set -euo pipefail
cd "$(dirname "$0")/../.."

set -a; . ./.env; set +a
NS="${NS:-agent-obs-platform}"
# The lab's own mc image (apps/mc/Dockerfile, `make mc-image`): Docker Hub no
# longer serves minio/mc. Same release as the binary on the VM.
MC_VERSION="${MC_VERSION:-RELEASE.2025-08-13T08-35-41Z}"
MC_IMAGE="${MC_IMAGE:-${REGISTRY:?set REGISTRY in .env}/agent-obs/mc:$MC_VERSION}"
POD="minio-verify-$$"
marker="agent-obs verify $(date -u +%FT%TZ) $RANDOM"

cleanup() { kubectl delete pod "$POD" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Round-tripping an object from a pod in $NS"
kubectl run "$POD" -n "$NS" --image="$MC_IMAGE" --restart=Never --quiet \
  --env="MC_HOST_minio=http://$MINIO_K8S_ACCESS_KEY:$MINIO_K8S_SECRET_KEY@${MINIO_ENDPOINT#http://}" \
  --env="MARKER=$marker" \
  --command -- sh -c '
    set -e
    echo "$MARKER" > /tmp/probe.txt
    mc cp --quiet /tmp/probe.txt minio/otel-archive/verify/probe.txt
    got=$(mc cat minio/otel-archive/verify/probe.txt)
    [ "$got" = "$MARKER" ] || { echo "MISMATCH: wrote [$MARKER] read [$got]"; exit 1; }
    echo "ROUNDTRIP_OK"
    mc rm --quiet minio/otel-archive/verify/probe.txt >/dev/null

    # Must be refused: not in the k8s-rw policy.
    if mc mb minio/should-be-denied >/dev/null 2>&1; then
      echo "SCOPE_FAIL: created a bucket outside the policy"; exit 1
    fi
    echo "SCOPE_OK"
  ' >/dev/null

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$POD" -n "$NS" --timeout=120s >/dev/null 2>&1 || true
out=$(kubectl logs "$POD" -n "$NS" 2>&1 || true)
phase=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)

echo "$out" | sed 's/^/    /'
if [ "$phase" = Succeeded ] && grep -q ROUNDTRIP_OK <<<"$out" && grep -q SCOPE_OK <<<"$out"; then
  echo "==> PASS: object round-tripped, and the credential is confined to MINIO_BUCKETS"
else
  echo "==> FAIL (pod phase: $phase)" >&2
  exit 1
fi
