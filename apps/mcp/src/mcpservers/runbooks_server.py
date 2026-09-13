"""MCP server: runbooks. Searches markdown documents baked into the image.

Evidence domain three of three. Deliberately a flat directory of markdown and a
substring search rather than embeddings and a vector store: the retrieval
quality is not what this project demonstrates, and a vector database would be a
hosted-service temptation and another component to explain.
"""

import os
import pathlib

from mcp.server.mcpserver import Context

from .server_base import build_server, guard, serve

RUNBOOKS = pathlib.Path(os.getenv("RUNBOOKS_DIR", "/runbooks"))

mcp = build_server("mcp-runbooks")


def _docs() -> list[pathlib.Path]:
    return sorted(RUNBOOKS.glob("*.md")) if RUNBOOKS.is_dir() else []


@mcp.tool()
def list_runbooks(ctx: Context) -> list[str]:
    """List available runbooks by name."""
    guard(ctx, "list_runbooks")
    return [p.stem for p in _docs()]


@mcp.tool()
def search_runbooks(ctx: Context, query: str, limit: int = 5) -> list[dict]:
    """Find runbooks mentioning a term. Returns name and matching lines."""
    guard(ctx, "search_runbooks")
    needle = query.lower().strip()
    if not needle:
        return []
    hits = []
    for p in _docs():
        lines = p.read_text(encoding="utf-8").splitlines()
        matches = [ln.strip() for ln in lines if needle in ln.lower()]
        if matches:
            hits.append({"runbook": p.stem, "matches": matches[:5]})
    return hits[:limit]


@mcp.tool()
def get_runbook(ctx: Context, name: str) -> str:
    """Return the full text of one runbook."""
    guard(ctx, "get_runbook")
    # Resolve and confirm containment: `name` arrives from model output and
    # '../../etc/passwd' is exactly the shape of thing that turns up there.
    target = (RUNBOOKS / f"{name}.md").resolve()
    if not str(target).startswith(str(RUNBOOKS.resolve())) or not target.is_file():
        return f"no such runbook: {name}"
    return target.read_text(encoding="utf-8")


if __name__ == "__main__":
    serve(mcp)
