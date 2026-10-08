# TODO

The project concluded on 2026-10-08; see *Where it ended* in the [README](README.md).
This is what was still open at that point, kept so the reader knows what the repository
does not claim. Each item says what is wrong, how that was established and where a fix
would go, ordered by how much it undermines what the lab claims.
[docs/alternatives.md](docs/alternatives.md) says what a reader could do differently
instead of fixing these in place.

## Open at conclusion

### Rotate the MinIO root password on the original lab

`deploy/05-minio/provision-vm.sh` passed the root password on the `sudo` command line, and
sudo logged it: one journal entry and one `/var/log/auth.log` line, written 2026-09-09 on
the original lab's MinIO VM. Counted on 2026-09-13 without printing the value. `auth.log`
is `syslog:adm 0640` and the `ubuntu` user is in `adm`, so it is readable without sudo.
The script was fixed the same day to pass credentials over stdin, so the single-VM lab
built on 2026-10-05 never logged it; the password written on the original lab stays valid
until it is rotated.

To rotate: set a new `MINIO_ROOT_PASSWORD` in `.env`, run `make minio-vm` (it rewrites
`/etc/default/minio` and restarts MinIO), then `make minio-verify`. The cluster's credential
is a separate MinIO user, and `minio-verify` confirms it still works and is still scoped.

### Deferred at the end of phase 3, 2026-09-13

- **A laptop path.** The single-VM path (done 2026-10-05) still needs a Proxmox host. A
  k3d variant with port-forwards and MinIO in-cluster is the shape; nothing in the
  manifests prevents it, and `deploy/01-cluster/` is where it would go.
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
  MLflow. The local 3B model scored 0 of 4 on the original lab and 1 of 4 on the single-VM
  one.
- **The Perses dashboards use 5-minute buckets fixed in SQL.** A `$step`-style variable
  would follow the time range.

### Found by the 2026-09-23 teardown and rebuild

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

### Lower priority

- **The analyser's 8192-token cap is unexercised.** It was raised after a truncation at
  4096, and no run since has needed more than 4096 (the next remote run used 1081). A
  reasonable ceiling, not yet a verified fix.
- **The CloudNativePG image comes from the operator's default.** Both clusters run
  `ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie` because operator 1.30.0 defaults
  to it; nothing in this repository names it. Set `spec.imageName` to the running value so
  an operator upgrade cannot change the databases silently.

## Closed

| Item | Closed | How |
| :- | :- | :- |
| `tool_belt` aborted the run when one MCP server was unreachable | 2026-09-13 | One exit scope per server, classified on close; `make mcp-degrade-test` covers a dead name and a black hole |
| Per-agent attribution used local names and skipped early exits | 2026-09-13 | Semconv names, `degraded` on every retriever exit, domain counting fixed |
| The MCP propagation experiment was left as stubs | 2026-09-13 | Closed with the measured answer: trace context travels in JSON-RPC `_meta` (SEP-414), not HTTP headers |
| An Ollama HTTPRoute that was never applied | 2026-09-13 | Deleted |
| No single-machine path | 2026-10-05 | `deploy/01-cluster/`: one k3s VM on a Proxmox host, every lab-specific value in `.env` |
| `make mcp-probe` reported a server fault for every tool call | 2026-10-05 | It sent no bearer token; it presents the reader token now |
| Model and run timeouts baked into the code | 2026-10-05 | `MODEL_TIMEOUT` and `TRIAGE_TIMEOUT` in `.env` |
