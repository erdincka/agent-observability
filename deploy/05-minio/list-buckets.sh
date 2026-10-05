#!/usr/bin/env bash
# Object counts and total size per bucket, from a throwaway in-cluster `mc`
# pod using the scoped credential. Usage: list-buckets.sh bucket [bucket...]
set -euo pipefail
cd "$(dirname "$0")/../.."
set -a; . ./.env; set +a
# The lab's own mc image (`make mc-image`); Docker Hub no longer serves minio/mc.
MC_IMAGE="${MC_IMAGE:-${REGISTRY:?set REGISTRY in .env}/agent-obs/mc:${MC_VERSION:-RELEASE.2025-08-13T08-35-41Z}}"
for b in "$@"; do
  kubectl run "mc-ls-$$" -n agent-obs-platform --rm -i --quiet --restart=Never \
    --image="$MC_IMAGE" \
    --env=MC_HOST_lab="http://${MINIO_K8S_ACCESS_KEY}:${MINIO_K8S_SECRET_KEY}@${MINIO_VM_IP}:9000" \
    --command -- sh -c "echo \"$b: \$(mc ls --recursive lab/$b 2>/dev/null | wc -l) objects, \$(mc du lab/$b 2>/dev/null)\"" 2>&1 | grep -v '^warning'
done
