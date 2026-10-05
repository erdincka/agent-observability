#!/usr/bin/env bash
# Build and push the lab's own MinIO client image (apps/mc/Dockerfile).
#
# Like scripts/build-image.sh, but tagged with the mc release rather than a
# commit: the binary is the whole input. An existing tag is reused, never
# rebuilt; FORCE=1 overrides.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }

REGISTRY="${REGISTRY:?set REGISTRY in .env}"
CTX="${DOCKER_BUILD_CONTEXT:?set DOCKER_BUILD_CONTEXT in .env (docker context ls)}"
# Same pin as deploy/05-minio/provision-vm.sh.
MC_VERSION="${MC_VERSION:-RELEASE.2025-08-13T08-35-41Z}"
MC_SHA256="${MC_SHA256:-01f866e9c5f9b87c2b09116fa5d7c06695b106242d829a8bb32990c00312e891}"
IMAGE="${REGISTRY}/agent-obs/mc:${MC_VERSION}"

if [ "${FORCE:-0}" != 1 ] && curl -fsS -o /dev/null -I \
     -H 'Accept: application/vnd.oci.image.index.v1+json' \
     -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
     "http://${REGISTRY}/v2/agent-obs/mc/manifests/${MC_VERSION}"; then
  echo "==> ${IMAGE} already exists; reusing it"
  exit 0
fi

echo "==> building ${IMAGE} on docker context ${CTX}"
docker --context "$CTX" build -f apps/mc/Dockerfile \
  --build-arg "MC_VERSION=${MC_VERSION}" --build-arg "MC_SHA256=${MC_SHA256}" \
  -t "${IMAGE}" apps/mc
echo "==> pushing to ${REGISTRY}"
docker --context "$CTX" push "${IMAGE}"
echo "==> ${IMAGE}"
