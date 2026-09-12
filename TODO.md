# TODO

Deferred work, recorded so it is not lost. Each item says what is wrong, how that was
established, and where the fix goes. Ordered by how much it undermines what the lab claims.
Items 1–5 came out of the review on 2026-09-13 and were deliberately left for a later round.

## 1. `tool_belt` aborts the run when one MCP server is unreachable

`apps/workflow/src/workflow/mcp_client.py`

The module docstring says connection failures are deliberately non-fatal: one unreachable
server should degrade the evidence and nothing more. It does the opposite. `tool_belt`
raises `ExceptionGroup: unhandled errors in a TaskGroup` **before it yields**, so the
retriever, and with it the whole run, fails.

Reproduced in-cluster against the running image, with one server pointed at a name that
does not resolve:

```bash
kubectl run belt-degrade -n agent-obs-app --rm -i --restart=Never \
  --image=10.1.1.240:5000/agent-obs/workflow:<tag> \
  --env=MCP_RUNBOOKS_URL=http://mcp-does-not-exist.agent-obs-app.svc.cluster.local:8080/mcp \
  --command -- python - <<'PY'
import asyncio
from workflow.mcp_client import tool_belt
async def main():
    async with tool_belt() as belt:
        print("degraded, unreachable:", sorted(belt.unreachable))  # never printed
asyncio.run(main())
PY
```

Likely cause, not yet confirmed from a traceback: the streamable-HTTP transport does its
network work in an anyio task group, a failed connection reaches the calling task as
cancellation, `except Exception` does not catch cancellation, and the task group re-raises
the connection error as an `ExceptionGroup` when the exit stack unwinds.

Knock-on effects: `belt.unreachable` is effectively never populated, and the retriever's
`if not belt.specs` branch only runs when servers are reachable but export no tools.

Fix direction: give each server its own exit scope inside the `try`, close it there on
failure, and catch the group (`except*`) without swallowing a genuine outer cancellation.
The repro above is the test.

## 2. Per-agent attribution: attribute names, and outcomes missing where they matter most

`apps/workflow/src/workflow/triage_graph.py` (`_Usage`), `__main__.py`, and a dated
correction under the 2026-09-11 entry in LEARNINGS.md

- **Reasoning tokens use a local name where a standard one exists.** Change
  `gen_ai.usage.reasoning_tokens` to `gen_ai.usage.reasoning.output_tokens`. It has been in
  the GenAI conventions since semconv v1.41.0 (2026-04-28), status Development, and now lives
  in `open-telemetry/semantic-conventions-genai`. The `stamp()` docstring and the LEARNINGS
  entry both say no standard attribute exists; correct that with a dated note rather than
  by rewriting the entry.
- **The docstring's aggregation advice does not work against these spans.** It says to
  aggregate with a `gen_ai.operation.name` filter, but `triage.agent <name>` spans carry no
  `gen_ai.operation.name`. Setting `gen_ai.operation.name=invoke_agent` and
  `gen_ai.agent.name=<node>`, both standard, makes the advice true: OpenLIT's own
  `invoke_agent` spans carry no usage keys, so filtering on `invoke_agent` sums exactly the
  per-agent figures. `triage.agent` then duplicates `gen_ai.agent.name`. The figures
  themselves are right — on run `e55d79a95f25`, retriever 10757 + analyser 1500 + reporter
  575 = 12832, equal to the gateway's input tokens over the run's 8 model calls.
- **The worst failures carry no outcome.** The retriever's no-tools early return exits
  before `usage.stamp()`, so that span has no `triage.outcome` and a
  `triage.outcome != 'ok'` filter misses it. The round-cap exit (`for … else`) stamps `ok`
  although evidence gathering was cut off. And `__main__.py` counts the
  `ERROR: no MCP tool server reachable …` evidence string as one covered domain.
- Optional: record `gen_ai.request.reasoning.level`, the standard answer to "was reasoning
  requested". No span in the lab carries it.

## 3. Close out the MCP propagation experiment

`apps/mcp/src/mcpservers/propagation.py`, `apps/mcp/src/mcpservers/server_base.py`,
`apps/workflow/src/workflow/mcp_client.py`

LEARNINGS answered the question on 2026-09-10 and re-checked it on 2026-09-11: trace context
crosses the agent → tool hop because the `mcp` 2.x SDK instruments both ends over HTTP
headers. MCP itself carries nothing, and a stdio transport would break the audit trail
without a word. The code still presents the question as open:

- `propagation.py` raises `NotImplementedError`, and its docstring poses the experiment.
- Every MCP server logs once that tool spans "may start a new trace instead of joining the
  caller's". That is now known to be false.
- `mcp_client.py`'s module docstring and its propagation-seam comment say wiring an injector
  would destroy a measurement that has already been taken.

Replace the stubs with the recorded answer, correct the warning and the comments, and
rebuild the MCP image.

## 4. Remove the Ollama HTTPRoute

`deploy/40-ollama/httproute.yaml`

Committed in `0e15e3d`, where a `git add -A` swept it in unreviewed. Never applied, and no
`make` target applies it. Applying it would expose the raw Ollama API at
`ollama.kube.local`: a model route with no key and no gateway span, around the control point
phase 2 depends on. Its comment calls it "the Ollama UI"; port 11434 is the API.
`make drift` reports it as unapplied until it is deleted.

## 5. Rotate the MinIO root password

MinIO VM, `10.1.1.20`

`deploy/05-minio/provision-vm.sh` passed the root password on the `sudo` command line, and
sudo logged it: one journal entry and one `/var/log/auth.log` line, written 2026-09-09.
Counted on 2026-09-13 without printing the value. `auth.log` is `syslog:adm 0640` and the
`ubuntu` user is in `adm`, so it is readable without sudo. The script was fixed on
2026-09-13 to pass credentials over stdin; the password already written stays valid until
it is rotated. Rotation was deliberately deferred.

To rotate: set a new `MINIO_ROOT_PASSWORD` in `.env`, run `make minio-vm` (it rewrites
`/etc/default/minio` and restarts MinIO), then `make minio-verify`. The cluster's credential
is a separate MinIO user, and `minio-verify` confirms it still works and is still scoped.

## Lower priority

- **The analyser's 8192-token cap is unexercised.** It was raised after a truncation at
  4096, and no run since has needed more than 4096 (the next remote run used 1081). A
  reasonable ceiling, not yet a verified fix.
- **The CloudNativePG image comes from the operator's default.** Both clusters run
  `ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie` because operator 1.30.0 defaults
  to it; nothing in this repository names it. Set `spec.imageName` to the running value so
  an operator upgrade cannot change the databases silently.
