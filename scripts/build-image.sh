#!/usr/bin/env bash
# Build and push an image on the pve Docker host.
#
# The workstation driving this project is arm64 macOS; the cluster is amd64.
# Building locally produces images that will not run, and the failure surfaces
# as a confusing exec-format error inside the pod rather than at build time.
# The pve context is a native x86_64 host, so this is a native build, not an
# emulated one.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: build-image.sh <app-dir-name> [tag] [context]}"
TAG="${2:-0.1.0}"
REGISTRY="10.1.1.240:5000"
IMAGE="${REGISTRY}/agent-obs/${APP}:${TAG}"

# Some apps need files from outside their own directory (the MCP servers bake in
# this repo's git history and docs/runbooks), so the build context is selectable.
CONTEXT="${3:-apps/${APP}}"

echo "==> building ${IMAGE} on docker context pve (native amd64)"
echo "    dockerfile: apps/${APP}/Dockerfile   context: ${CONTEXT}"
docker --context pve build -f "apps/${APP}/Dockerfile" -t "${IMAGE}" "${CONTEXT}"

echo "==> pushing to the in-cluster registry"
docker --context pve push "${IMAGE}"

echo "==> ${IMAGE}"
