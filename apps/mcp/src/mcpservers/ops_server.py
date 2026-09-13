"""MCP server: ops. One tool that changes state, so there is something to deny.

The other three servers are read-only, and a policy over read-only tools
demonstrates nothing an auditor would care about. This server can restart a
deployment. Whether the calling role is allowed to is decided in
`server_base.guard`, and the decision lands on the span either way.

The Kubernetes API is called directly with the pod's service-account token —
no client library, because the only calls are a list and a patch, and the
RBAC that scopes them (see deploy/80-mcp/servers.yaml) is the part worth
reading: this server can touch Deployments in its own namespace and nothing
else, which is the blast radius the policy is protecting.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import pathlib

import httpx
from mcp.server.mcpserver import Context

from .server_base import build_server, guard, serve

SA = pathlib.Path("/var/run/secrets/kubernetes.io/serviceaccount")
API = os.getenv("KUBERNETES_API", "https://kubernetes.default.svc")
NAMESPACE = os.getenv("OPS_NAMESPACE") or (SA / "namespace").read_text().strip() if (SA / "namespace").exists() else "agent-obs-app"

mcp = build_server("mcp-ops")


def _client() -> httpx.Client:
    token = (SA / "token").read_text().strip()
    return httpx.Client(
        base_url=API,
        headers={"Authorization": f"Bearer {token}"},
        verify=str(SA / "ca.crt"),
        timeout=30,
    )


@mcp.tool()
def list_deployments(ctx: Context) -> list[dict]:
    """List deployments in this namespace with replica counts and last restart."""
    guard(ctx, "list_deployments", resource=f"k8s:deployments/{NAMESPACE}")
    with _client() as c:
        r = c.get(f"/apis/apps/v1/namespaces/{NAMESPACE}/deployments")
        r.raise_for_status()
    out = []
    for d in r.json().get("items", []):
        ann = d["spec"]["template"]["metadata"].get("annotations") or {}
        out.append({
            "name": d["metadata"]["name"],
            "ready": d.get("status", {}).get("readyReplicas", 0),
            "replicas": d["spec"].get("replicas", 0),
            "last_restart": ann.get("kubectl.kubernetes.io/restartedAt", ""),
        })
    return out


@mcp.tool()
def restart_deployment(ctx: Context, name: str) -> dict:
    """Roll-restart one deployment in this namespace. Changes state: needs the operator role."""
    guard(ctx, "restart_deployment", resource=f"k8s:deployments/{NAMESPACE}/{name}", name=name)
    patch = {
        "spec": {"template": {"metadata": {"annotations": {
            "kubectl.kubernetes.io/restartedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "agent-obs.io/restarted-by": "mcp-ops",
        }}}}
    }
    with _client() as c:
        r = c.patch(
            f"/apis/apps/v1/namespaces/{NAMESPACE}/deployments/{name}",
            content=json.dumps(patch),
            headers={"Content-Type": "application/strategic-merge-patch+json"},
        )
        if r.status_code == 404:
            return {"restarted": False, "error": f"no deployment {name!r} in {NAMESPACE}"}
        r.raise_for_status()
    return {"restarted": True, "deployment": name, "namespace": NAMESPACE}


if __name__ == "__main__":
    serve(mcp)
