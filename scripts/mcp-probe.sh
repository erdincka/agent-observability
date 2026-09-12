#!/usr/bin/env bash
# Speak MCP to each tool server: initialize, list tools, call one.
#
# Runs inside the cluster using the servers' own image, so the MCP client
# library is already present and no local Python environment is required.
set -euo pipefail
cd "$(dirname "$0")/.."

kubectl run "mcp-probe-$$" --namespace agent-obs-app --rm -i --quiet --restart=Never \
    --image="10.1.1.240:5000/agent-obs/mcp:$(scripts/image-tag.sh mcp)" -- python - <<'PY'
import asyncio

from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

SERVERS = [
    ("mcp-metrics",  "active_alerts",  {}),
    ("mcp-changes",  "recent_commits", {"limit": 3}),
    ("mcp-runbooks", "list_runbooks",  {}),
]


async def probe(host: str, tool: str, args: dict) -> None:
    url = f"http://{host}.agent-obs-app.svc.cluster.local:8080/mcp"
    async with streamable_http_client(url) as (read, write):
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
