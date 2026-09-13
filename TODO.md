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

## Lower priority

- **The analyser's 8192-token cap is unexercised.** It was raised after a truncation at
  4096, and no run since has needed more than 4096 (the next remote run used 1081). A
  reasonable ceiling, not yet a verified fix.
- **The CloudNativePG image comes from the operator's default.** Both clusters run
  `ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie` because operator 1.30.0 defaults
  to it; nothing in this repository names it. Set `spec.imageName` to the running value so
  an operator upgrade cannot change the databases silently.
