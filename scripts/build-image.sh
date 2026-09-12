#!/usr/bin/env bash
# Build and push an app image on the pve Docker host.
#
# Native amd64. The workstation is arm64 macOS and the cluster is amd64; an image
# built locally fails inside the pod with an exec-format error rather than at
# build time. The `pve` Docker context is an x86_64 VM, so this is a native build.
#
# Tags are immutable. The tag is the last commit that touched the app's inputs
# (scripts/image-tag.sh), and a clean tag that already exists in the registry is
# reused, never rebuilt. So a tag names exactly one image and the manifests can
# use `imagePullPolicy: IfNotPresent`. The `0.1.0` tag this replaces was rebuilt
# in place, and pods kept serving cached code (LEARNINGS.md, step 5).
#
# Uncommitted changes to the inputs produce a `<sha>-dirty` tag. Those rebuild
# every time and deploy with `imagePullPolicy: Always`, so iteration still works
# and nothing presents a dirty build as a commit.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: build-image.sh <app> [context]}"
# Some images need files from outside their own directory: the MCP servers bake
# in docs/runbooks and this repository's git history, so their context is `.`.
CONTEXT="${2:-apps/${APP}}"
REGISTRY="${REGISTRY:-10.1.1.240:5000}"
TAG="$(scripts/image-tag.sh "$APP")"
IMAGE="${REGISTRY}/agent-obs/${APP}:${TAG}"

if [[ "$TAG" == *-dirty ]]; then
  echo "==> WARNING: uncommitted changes in ${APP}'s inputs; building mutable tag ${TAG}" >&2
elif curl -fsS -o /dev/null -I \
       -H 'Accept: application/vnd.oci.image.index.v1+json' \
       -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
       "http://${REGISTRY}/v2/agent-obs/${APP}/manifests/${TAG}"; then
  if [ "${FORCE:-0}" != 1 ]; then
    echo "==> ${IMAGE} already exists; tags are immutable, reusing it"
    exit 0
  fi
  echo "==> WARNING: FORCE=1 overwrites ${TAG}; nodes that cached it will not notice" >&2
fi

echo "==> building ${IMAGE} on docker context pve (native amd64)"
echo "    dockerfile: apps/${APP}/Dockerfile   context: ${CONTEXT}"
docker --context pve build -f "apps/${APP}/Dockerfile" -t "${IMAGE}" "${CONTEXT}"

echo "==> pushing to the in-cluster registry"
docker --context pve push "${IMAGE}"
echo "==> ${IMAGE}"
echo "    $(docker --context pve image inspect --format '{{index .RepoDigests 0}}' "${IMAGE}")"
