# 0. The stack, and how the pieces relate

**Question it answers:** which component does what, which ones can *see* an agent's
actions, and which ones can *decide* about them.
**Status:** built. Everything on this page is deployed and has been exercised.

## The two kinds of component

Every component in this lab is one of two things. It either **produces or carries
telemetry** about what the agent does, or it is a **control point** where a decision
about the agent can be enforced. A few are both. Keeping the distinction in mind is what
makes the later chapters make sense: observability without a control point is a report,
and a control point without telemetry is a rule nobody can prove was applied.

| Component | Role in the lab | Emits telemetry | Propagates trace context | Control point for |
| :- | :- | :- | :- | :- |
| LangGraph workflow (`apps/workflow`) | The specimen. Three agents, one incident, real handoffs. | Yes, via the OpenLIT SDK | Yes. Injects `traceparent` on every outbound HTTP call | Nothing. It is the thing being watched. |
| MCP tool servers (`apps/mcp`) | The agent's only route to data: metrics, git history, runbooks. | Yes, via the `mcp` SDK and OpenLIT | Yes. The `mcp` 2.x SDK carries `traceparent` in JSON-RPC `_meta` | Tool access, in chapter 7 |
| LiteLLM gateway | The agent's only route to a model. | Yes, OTel v2 on the GenAI conventions | Yes. Joins an incoming trace rather than starting one | Identity, budgets, model access, content posture |
| Ollama | The default model. CPU, 3B parameters. | No | n/a | Nothing |
| OTel Collector (contrib) | The pipeline, and the **only writer** into storage. | n/a | n/a | Redaction, routing, sampling, retention |
| ClickHouse | Hot store for traces, metrics, logs. | No | n/a | Nothing. Storage is not policy. |
| OpenLIT UI | A read-only view over the same tables. | No | n/a | Nothing |
| PostgreSQL, two clusters | Workflow state and checkpoints; the gateway's identity tables. | No | n/a | Nothing directly. The gateway's controls live in its database. |
| MinIO, on a VM outside the cluster | Retention tier. Deployed, **not yet wired** to anything. | No | n/a | Retention and immutability, in chapter 8 |
| Perses | Dashboards as code. **Not deployed.** | No | n/a | Nothing |

The diagram in the [README](../../README.md) shows the same thing as arrows.

## The two control points

The brief names two, and phase 1 confirmed both are the right ones.

**The gateway enforces at the boundary, before the call happens.** Every model call
passes through it, so it is the one place that can answer "which model, on whose key, at
what cost" and the one place that can refuse. Phase 1 runs it as a passthrough on the
master key. Chapter 6 turns that into per-agent identity.

**The Collector processes after the fact, before anything is stored.** Every span from
every component passes through it, so it is the one place that can redact, route, sample
and archive uniformly. That only works because it is the sole writer: an OpenLIT that
ingested its own telemetry, or an SDK exporting straight to ClickHouse, would bypass it.
Chapter 1 shows why the write path was claimed on day one.

## The four questions and the claim

The project's own framing: regulated
organisations often cannot store prompt or completion content, and still have to answer

1. **What did the agent do?**
2. **On whose behalf?**
3. **With what data access?**
4. **Can you prove it later?**

The claim under test is that a platform can produce **audit-grade agent traces without
recording the content**. The [governance matrix](../governance-matrix.md) tracks, per
question, which control provides the answer, what evidence lands in the trace, and where
the answer is still "no".

## What is deliberately not here, and why

- **No Tempo.** With ClickHouse as the trace store and OpenLIT reading it, a second trace
  store is complexity without benefit. A Tempo does run in this lab from other work; it is
  not used, and its presence on the same OTLP ports is a documented hazard.
- **No Grafana.** Perses was chosen for phase 3 because it is early enough that a
  dashboards-as-code example for GenAI telemetry is novel there, and contribution value was
  ranked above demo polish. That decision produced the project's first upstream PR before
  Perses was even deployed here.
- **No sandbox or isolation layer.** Visibility and attribution are a different property
  from confinement. This lab shows what an agent did; it does not stop it.
- **No visual builder.** A layer that adds nothing to governance.
- **MLflow deferred.** The brief keeps it for the evaluation loop, "was it right" as
  opposed to "what did it do". It is chapter 11, optional, and not on the MVP path.

## Read more

- LEARNINGS.md: *Lab inventory* and *Decisions taken before deployment* (2026-09-09), and
  *Phase 1 write-up* (2026-09-13).
