#!/usr/bin/env bash
# Speak MCP to each tool server: initialize, list tools, call one.
#
# Runs inside the cluster using the servers' own image, so the MCP client
# library is already present and no local Python environment is required.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }
REGISTRY="${REGISTRY:?set REGISTRY in .env}"

# Runs with the workflow's network identity, deliberately. Chapter 7's
# mcp-ingress-from-workflow policy admits port 8080 only from pods labelled
# app.kubernetes.io/name=workflow, and governed-default-deny-egress is what
# permits DNS out. Without both labels this pod is refused by the policy —
# which is the policy working, but it makes the helper useless after `make
# netpol`. This client runs the workflow's own code, so borrowing the
# workflow's identity is honest rather than a loophole.
#
# It presents the reader role's bearer token too (chapter 7). Without one the
# servers classify the caller as `anonymous`, a role the policy does not list,
# and every call comes back "Error executing tool" — tools/list succeeds, so
# the output looks like a server fault rather than an authorization refusal.
# Found on the 2026-10-05 rebuild; the probe had been reporting that since
# the policy was first applied.
: "${TOOL_TOKEN_READER:?set TOOL_TOKEN_READER in .env}"

kubectl run "mcp-probe-$$" --namespace agent-obs-app --rm -i --quiet --restart=Never \
--labels=app.kubernetes.io/name=workflow,agent-obs.io/governed=true \
    --env=TOOL_TOKEN="$TOOL_TOKEN_READER" \
    --image="${REGISTRY}/agent-obs/mcp:$(scripts/image-tag.sh mcp)" -- python - <<'PY'
import asyncio
import os

from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client
from mcp.shared._httpx_utils import create_mcp_http_client

HEADERS = {"Authorization": f"Bearer {os.environ['TOOL_TOKEN']}"}

SERVERS = [
    ("mcp-metrics",  "active_alerts",  {}),
    ("mcp-changes",  "recent_commits", {"limit": 3}),
    ("mcp-runbooks", "list_runbooks",  {}),
]


async def probe(host: str, tool: str, args: dict) -> None:
    url = f"http://{host}.agent-obs-app.svc.cluster.local:8080/mcp"
    async with create_mcp_http_client(headers=HEADERS) as client, \
            streamable_http_client(url, http_client=client) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            listing = await session.list_tools()
            print(f"\n=== {host} ===")
            print("  tools: " + ", ".join(t.name for t in listing.tools))
            result = await session.call_tool(tool, args)
            text = "".join(
                getattr(c, "text", "") for c in result.content
            ).strip().replace("\n", " ")
            print(f"  {tool}() -> {text[:220]}")


async def main() -> None:
    for host, tool, args in SERVERS:
        try:
            await probe(host, tool, args)
        except Exception as exc:  # noqa: BLE001 - a probe reports, it does not raise
            print(f"\n=== {host} ===\n  FAILED: {exc!r}")


asyncio.run(main())
PY
