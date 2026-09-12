#!/usr/bin/env bash
# Print the immutable image tag for an app: the last commit that touched the
# files its image is built from, 12 hex characters, plus `-dirty` if those files
# have uncommitted changes, because then the image is not that commit.
#
# Keyed to the app's inputs rather than HEAD on purpose. With HEAD, every
# LEARNINGS.md edit would change the tag the Jobs and Deployments reference, and
# point the cluster at an image that was never built.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:?usage: image-tag.sh <workflow|mcp>}"
case "$app" in
  workflow) inputs=(apps/workflow) ;;
  # The MCP image also bakes in docs/runbooks. It bakes in .git as well, for the
  # changes server, but that is a snapshot of history taken at first build, not
  # an input: an existing clean tag is never rebuilt (scripts/build-image.sh).
  mcp)      inputs=(apps/mcp docs/runbooks) ;;
  *) echo "image-tag.sh: unknown app '$app'" >&2; exit 2 ;;
esac

sha=$(git log -1 --format=%H -- "${inputs[@]}" | cut -c1-12)
[ -n "$sha" ] || { echo "image-tag.sh: no commit touches ${inputs[*]}" >&2; exit 1; }

if [ -n "$(git status --porcelain -- "${inputs[@]}")" ]; then
  echo "${sha}-dirty"
else
  echo "$sha"
fi
