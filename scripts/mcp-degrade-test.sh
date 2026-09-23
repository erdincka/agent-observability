#!/usr/bin/env bash
# The test for TODO item 1: one unreachable tool server must degrade the run,
# not abort it. Three cases, run in-cluster against the current workflow image:
#   1. all three servers reachable            -> 0 unreachable, tools > 0
#   2. one server pointed at a dead name      -> 1 unreachable, tools > 0
#   3. one server pointed at a black hole     -> 1 unreachable (timeout), tools > 0
# Exits non-zero if any case aborts or reports the wrong count.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=agent-obs-app
TAG=$(scripts/image-tag.sh workflow)
POLICY=IfNotPresent; case "$TAG" in *-dirty) POLICY=Always;; esac

SNIPPET='
import asyncio, logging
logging.basicConfig(level=logging.WARNING)
from workflow.mcp_client import tool_belt
async def main():
    async with tool_belt() as belt:
        print(f"RESULT unreachable={len(belt.unreachable)} tools={len(belt.specs)} {sorted(belt.unreachable)}")
asyncio.run(main())
'

run_case() {
  local label="$1" expect="$2"; shift 2
  echo "== $label"
  # Runs with the workflow's network identity, deliberately. Chapter 7's
  # mcp-ingress-from-workflow policy admits port 8080 only from pods labelled
  # app.kubernetes.io/name=workflow, and governed-default-deny-egress is what
  # permits DNS out. Without both labels this pod is refused by the policy —
  # which is the policy working, but it makes the helper useless after `make
  # netpol`. This client runs the workflow's own code, so borrowing the
  # workflow's identity is honest rather than a loophole.

  kubectl run "belt-test-$$" -n "$NS" --rm -i --restart=Never --quiet \
  --labels=app.kubernetes.io/name=workflow,agent-obs.io/governed=true \
    --image="10.1.1.240:5000/agent-obs/workflow:$TAG" --image-pull-policy="$POLICY" \
    --env=MCP_CONNECT_TIMEOUT=5 "$@" \
    --command -- python -c "$SNIPPET" 2>&1 | tee /dev/stderr | grep -q "^RESULT unreachable=$expect tools=[1-9]"
}

run_case "all reachable" 0
run_case "one dead name" 1 \
  --env=MCP_RUNBOOKS_URL=http://mcp-does-not-exist.agent-obs-app.svc.cluster.local:8080/mcp
# 10.255.255.1 is unrouted from the cluster: SYNs go nowhere, which is the
# hang the connect timeout exists for.
run_case "one black hole" 1 \
  --env=MCP_CHANGES_URL=http://10.255.255.1:8080/mcp
echo "all three cases degraded correctly"
