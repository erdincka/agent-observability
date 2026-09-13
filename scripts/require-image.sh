#!/usr/bin/env bash
# Fail, naming the command that fixes it, when the image an app's manifests are
# about to reference is not in the registry. Without this the first sign is
# ImagePullBackOff on a pod a minute later, in a different terminal.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:?usage: require-image.sh <workflow|mcp|perses>}"
REGISTRY="${REGISTRY:-10.1.1.240:5000}"
tag=$(scripts/image-tag.sh "$app")

if curl -fsS -o /dev/null -I \
     -H 'Accept: application/vnd.oci.image.index.v1+json' \
     -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
     "http://${REGISTRY}/v2/agent-obs/${app}/manifests/${tag}"; then
  exit 0
fi
echo "ERROR: agent-obs/${app}:${tag} is not in the registry. Run: make ${app}-image" >&2
exit 1
