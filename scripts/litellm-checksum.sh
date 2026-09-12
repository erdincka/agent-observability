#!/usr/bin/env bash
# The LiteLLM Deployment's `checksum/config` annotation: a hash over the rendered
# gateway config and every credential the pod reads from litellm-auth.
#
# A ConfigMap or Secret change does not restart a pod on its own; changing this
# annotation is what forces the rollout. Shared by `make litellm` and
# `make drift` so the two cannot disagree. When litellm-auth gains a key, add it
# here, or changing that key will not restart the gateway — the step 3 Makefile
# trap in LEARNINGS.md.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
{ cat deploy/50-litellm/config.rendered.yaml
  echo "${OPENROUTER_API_KEY:-}${LITELLM_MASTER_KEY:-}${OLLAMA_BASE_URL:-}"
  echo "${LITELLM_SALT_KEY:-}${LITELLM_UI_USERNAME:-}${LITELLM_UI_PASSWORD:-}"
} | shasum -a 256 | cut -c1-16
