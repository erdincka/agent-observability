# TODO

Deferred work, recorded so it is not lost. Each item says what is wrong, how that was
established, and where the fix goes. Ordered by how much it undermines what the lab claims.
Items 1–5 came out of the review on 2026-09-13 and were deliberately left for a later round;
items 2 and 3 were closed later the same day.

## 1. `tool_belt` aborts the run when one MCP server is unreachable — done 2026-09-13

Each server now connects on its own `AsyncExitStack`; a failure closes that scope and
classifies what the close raises (an `ExceptionGroup` of plain exceptions is the SDK's
transport failing and degrades the run; a cancellation is genuine and propagates). A
connect timeout (`MCP_CONNECT_TIMEOUT`, default 10 s) covers a black-holing server.
`make mcp-degrade-test` runs three in-cluster cases: all reachable, one dead name, one
black hole. All three pass. See LEARNINGS.md, 2026-09-13.

## 2. Per-agent attribution — done 2026-09-13

Semconv names, `degraded` outcome on every retriever exit, and domain counting fixed.
Verified on runs `578213f4002f` and `7198ffdf993d`; see LEARNINGS.md. The optional
`gen_ai.request.reasoning.level` is still not recorded: the workflow does not request a
reasoning level, so there is nothing truthful to put there yet.

## 3. Close out the MCP propagation experiment — done 2026-09-13

Stubs replaced with the recorded answer, warning inverted, MCP image rebuilt. Closing it
corrected the answer: trace context travels in JSON-RPC `_meta` (SEP-414), not HTTP
headers. See LEARNINGS.md.

## 4. Remove the Ollama HTTPRoute — done 2026-09-13

Deleted from the tree. It was never applied.

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

## Deferred at the end of phase 3, 2026-09-13

- **A single-machine path.** The guide's commands assume this lab (docs/lab-environment.md
  marks what is lab-specific). A k3d or single-node variant with port-forwards instead of
  the gateway, a local registry, and MinIO in-cluster would let a reader run the guide on
  a laptop. Deliberately left: the review happens on this lab.
- **Object lock on the archive bucket, and the receipt digest written there.** Versioning
  stops silent overwrite; nothing stops deletion. Chapter 9 names the shape.
- **Rate-limit refusals are not attributed on the 429 span.** Which key hit the limit is in
  the gateway log. Possibly a LiteLLM contribution.
- **`gen_ai.request.reasoning.level`** is still recorded nowhere; the workflow does not
  request a level.
- **MLflow's evaluation is regular expressions.** An LLM judge on the `remote` route would
  be the next step, scored against the same `correct` metric. The first pass showed the
  specific gap: irrelevant tool output counts as evidence, so
  `confident_cause_without_evidence` cannot fire on the incident it was written for.
- **Run the evaluation on the `remote` route** (needs the external key) and compare in
  MLflow; the local 3B model scored 0 of 4.
- **The Perses dashboards use 5-minute buckets fixed in SQL.** A `$step`-style variable
  would follow the time range.

## Found by the 2026-09-23 teardown and rebuild

- **The MCP containers have no readinessProbe.** `kubectl rollout status` therefore returns
  while uvicorn is still binding, and anything that connects immediately afterwards fails
  with `ConnectError`. Add an HTTP or TCP probe on 8080 so "rolled out" means "listening".
  This cost real debugging time because it shares its error string with a NetworkPolicy
  refusal; see LEARNINGS.md, 2026-09-23.
- **LiteLLM's own housekeeping spans dominate a quiet day.** `postgres get_data`,
  `postgres get_user_object` and `reset_budget_job ...` arrive continuously under the
  `litellm-gateway` service name, about 1,150 spans a day with no agent running. Decide
  whether to drop them in the Collector (they are noise in every count and in the retention
  figures) or to keep them and always filter in queries. If they are kept, the guide should
  say so where it counts spans.

## Lower priority

- **The analyser's 8192-token cap is unexercised.** It was raised after a truncation at
  4096, and no run since has needed more than 4096 (the next remote run used 1081). A
  reasonable ceiling, not yet a verified fix.
- **The CloudNativePG image comes from the operator's default.** Both clusters run
  `ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie` because operator 1.30.0 defaults
  to it; nothing in this repository names it. Set `spec.imageName` to the running value so
  an operator upgrade cannot change the databases silently.
