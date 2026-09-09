"""MCP server: changes. Reads this repository's own git history.

Evidence domain two of three. "What changed recently" is the second question in
any real triage, and pointing it at this repo keeps the whole lab reproducible
from a clone — no external repository, no credentials, no network.
"""

import os
import subprocess

from mcp.server.mcpserver import Context

from .server_base import build_server, join_caller_trace, serve

REPO = os.getenv("GIT_REPO_PATH", "/repo")

mcp = build_server("mcp-changes")


def _git(*args: str) -> str:
    """Run git in the baked-in repo.

    Arguments are passed as a list, never through a shell, so a tool argument
    cannot become a command. Worth being deliberate about: tool arguments here
    arrive from a model's output.
    """
    result = subprocess.run(
        ["git", "-C", REPO, *args],
        capture_output=True, text=True, timeout=30, check=False,
    )
    if result.returncode != 0:
        return f"git error: {result.stderr.strip()}"
    return result.stdout.strip()


@mcp.tool()
def recent_commits(ctx: Context, limit: int = 10) -> list[dict]:
    """List recent commits, most recent first."""
    join_caller_trace(ctx)
    limit = max(1, min(limit, 100))
    out = _git("log", f"-{limit}", "--pretty=format:%H%x1f%an%x1f%ar%x1f%s")
    commits = []
    for line in out.splitlines():
        parts = line.split("\x1f")
        if len(parts) == 4:
            commits.append(
                {"sha": parts[0][:12], "author": parts[1], "when": parts[2], "subject": parts[3]}
            )
    return commits


@mcp.tool()
def commit_detail(ctx: Context, sha: str) -> str:
    """Show the message and changed-file stat for one commit."""
    join_caller_trace(ctx)
    if not sha.replace("-", "").isalnum():
        return "invalid revision"
    return _git("show", "--stat", "--pretty=medium", sha)


@mcp.tool()
def files_changed_since(ctx: Context, rev: str = "HEAD~5") -> list[str]:
    """List files changed since a revision — the 'what moved' question."""
    join_caller_trace(ctx)
    if not rev.replace("~", "").replace("^", "").replace("-", "").isalnum():
        return ["invalid revision"]
    out = _git("diff", "--name-only", f"{rev}..HEAD")
    return [line for line in out.splitlines() if line]


if __name__ == "__main__":
    serve(mcp)
