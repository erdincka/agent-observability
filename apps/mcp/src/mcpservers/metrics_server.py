"""MCP server: metrics. Queries the Prometheus already running in this lab.

Evidence domain one of three. Nothing external — this is the lab observing
itself, which is also why the data is real rather than fixtures.
"""

import os

import httpx
from mcp.server.mcpserver import Context

from .server_base import build_server, join_caller_trace, serve

PROMETHEUS_URL = os.getenv(
    "PROMETHEUS_URL",
    "http://kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090",
)

mcp = build_server("mcp-metrics")


@mcp.tool()
def instant_query(ctx: Context, promql: str) -> dict:
    """Run an instant PromQL query. Returns the raw Prometheus result.

    Args:
        promql: a PromQL expression, e.g. 'up' or 'rate(node_cpu_seconds_total[5m])'
    """
    join_caller_trace(ctx)
    r = httpx.get(f"{PROMETHEUS_URL}/api/v1/query", params={"query": promql}, timeout=30)
    r.raise_for_status()
    return r.json()


@mcp.tool()
def list_metric_names(ctx: Context, prefix: str = "", limit: int = 50) -> list[str]:
    """List metric names known to Prometheus, optionally filtered by prefix."""
    join_caller_trace(ctx)
    r = httpx.get(f"{PROMETHEUS_URL}/api/v1/label/__name__/values", timeout=30)
    r.raise_for_status()
    names = r.json().get("data", [])
    if prefix:
        names = [n for n in names if n.startswith(prefix)]
    return names[:limit]


@mcp.tool()
def active_alerts(ctx: Context) -> dict:
    """Return currently firing Prometheus alerts — the usual start of a triage."""
    join_caller_trace(ctx)
    r = httpx.get(f"{PROMETHEUS_URL}/api/v1/alerts", timeout=30)
    r.raise_for_status()
    return r.json()


if __name__ == "__main__":
    serve(mcp)
