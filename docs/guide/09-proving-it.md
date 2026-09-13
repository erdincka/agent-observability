# 9. Proving it later

**Question it answers:** can a reviewer who was not there establish, from the stored
record alone, what an agent did, and trust that the record is whole and unaltered?
**Status:** built 2026-09-13. One command per run; every check is a query over the
standard tables.
**Tools:** ClickHouse, the restricted store, MinIO, `scripts/receipt.sh`.

## Run

```bash
make runs                     # recent runs with the outcome of each agent
make receipt RUN=<run id>     # the receipt
```

## What you should see

For run `4b6e29c54965`, the content-redaction demo where the model also tried to restart
a deployment:

```
== 1. completeness   (180 spans; services: litellm-gateway, mcp-changes, mcp-metrics, mcp-ops, mcp-runbooks, triage-workflow)
  [ok]   no span points at a parent that was never exported
== 2. reconciliation   (agents in=10095 out=504; gateway in=10095 out=504)
  [ok]   agent-side token sums equal gateway-side sums
== 3. agents
  retriever degraded  calls=6 in=8687 out=128 reasoning=0 degraded=round_cap
  analyser  ok        calls=1 in=993 out=33 reasoning=0
  reporter  ok        calls=1 in=415 out=343 reasoning=0
== 4. model calls, as the gateway saw them
  agent-retriever   ollama_chat/qwen2.5:3b   calls=6 end_user=oncall-engineer
  ...
== 5. tool calls, as the servers saw them
  mcp-ops      restart_deployment    deny  retriever reader   k8s:deployments/agent-obs-app/checkout-service args#59b8dcd800b82dd2
  ...
== 6. content   (spans with redaction applied: 74)
  [ok]   no prompt, completion or incident text in any stored span attribute
  [ok]   none in any stored log record
== 7. routing   (flagged spans: 3; copies in the restricted store: 180)
  [ok]   a flagged trace is present, whole, in the restricted store
== 8. digest   sha256 over every span's id, parent, name, service, duration and attributes, sorted
  A5111E5D…
== result: every check passed
```

## What it means

**An auditor does not read traces; they run checks.** Eight of them, each a query, each
with a pass condition a reviewer can read. Completeness and reconciliation are the two
that catch silent loss; content and routing are the two that show the controls held;
the tables in between are what the agent did, by whom, on what. The digest is the
fingerprint of the record as stored: recompute it later and a difference means the
record changed.

**Everything the receipt reads is on standard tables under mostly standard names.** Where
a name is local (`triage.*`, `authz.*`, `agent_obs.*`), the guide says so. The same
script runs against any Collector-to-ClickHouse deployment that adopts the same
attributes, which is the point of putting them on spans rather than in a log line.

**The digest is a receipt, not a proof of immutability.** It is computed from the hot
store and, in this lab, written to a local file. In a deployment it belongs in the
archive bucket next to the batch it covers, under object lock. The archive itself
(chapter 8) is versioned, so an object once written cannot be silently replaced; nothing
yet prevents deletion.

## Where it breaks

- The digest covers spans, not log records or metrics.
- "Every check passed" on a run whose trace never arrived is impossible only because the
  receipt refuses to run without a trace. A run that produced no telemetry at all leaves
  no receipt, and that absence has to be noticed by something else (the runs list).
- Reconciliation compares agent-side and gateway-side sums; a run where both are wrong in
  the same way passes.

## In an enterprise

Retention is a property of the archive; provability is a property of the checks. This
chapter is the second half: a reviewer with read access to the store and this script
reaches the same conclusions the author did, without the author.

## Read more

- `scripts/receipt.sh`; LEARNINGS.md, 2026-09-13: *Chapters 9 and 10*.
