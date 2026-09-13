# Decisions and assumptions

Recorded as they were made, with the alternative not taken. Newest last. LEARNINGS.md has
the evidence behind each; this page is the index of what was decided and why.

| Date | Decision | Alternative not taken | Why |
| :- | :- | :- | :- |
| 2026-09-09 | The Collector is the only writer to ClickHouse; OpenLIT reads only | OpenLIT's bundled collector and ClickHouse | Governance controls live in the pipeline; two writers means no control point |
| 2026-09-09 | Every model call goes through LiteLLM; the workflow names routes, never models | Direct provider clients | One place to observe and later enforce model access |
| 2026-09-09 | Local Ollama is the committed default; the external route is opt-in | External model as default | The self-hosted claim has to be true of the repository as published |
| 2026-09-09 | MCP servers are separate pods over streamable HTTP | stdio subprocesses | A network hop makes propagation observable as two services in one trace |
| 2026-09-09 | Two namespaces, platform and app | One | The governance boundary runs along it |
| 2026-09-09 | MinIO on a VM outside the cluster | In-cluster | The durable tier cannot depend on the cluster it backs |
| 2026-09-09 | Content capture off at every layer, verified by grep | Trust the settings | A posture that depends on a default is not a posture |
| 2026-09-10 | Tool selection left to the model; baseline is a distribution | Sweep all tools deterministically | A lab that watches agents decide needs decisions to watch |
| 2026-09-11 | Per-agent usage on spans the workflow owns | Write to the ambient span | The ambient span is OpenLIT's ended LLM span; writes vanish |
| 2026-09-13 | The repository is a guide and a playground, not a platform | Continue hardening the lab | Findings and reproducible experiments are the product |
| 2026-09-13 | Standard attribute names where they exist (`gen_ai.usage.reasoning.output_tokens`, `gen_ai.agent.name`); `triage.*` only for what has no standard | Local names throughout | Portable queries; the local vocabulary is flagged as such |
| 2026-09-13 | Outcome vocabulary: `denied` > `truncated` > `empty` > `degraded` > `ok`, worst first | Finish reason only | A one-token `stop` is an empty report; a policy refusal is not a crash |
| 2026-09-13 | One exit scope per tool server; classify what its close raises | Catch `Exception` | The SDK's task group delivers failures as cancellations |
| 2026-09-13 | Identity: principal and agent in baggage for attribution; virtual key and bearer token for enforcement | Baggage for both | Baggage is an assertion (SEP-414 says so); enforcement needs a verified credential |
| 2026-09-13 | End-user id promoted onto gateway spans (off by default in LiteLLM) | Leave it off | "On whose behalf" is one of the four questions; the switch is one visible env var |
| 2026-09-13 | Per-agent virtual keys, deterministic from the master key, minted inside the gateway pod | Random keys stored in a file; minting from the workstation | Re-runnable, no route needed from the workstation, master key never leaves the pod |
| 2026-09-13 | A fourth tool server with one state-changing tool, restricted by RBAC to its own namespace | Deny a read-only tool | A policy over read-only tools demonstrates nothing an auditor cares about |
| 2026-09-13 | Role→tool policy as a ConfigMap; static bearer tokens | Policy engine; signed workload identity | Smallest thing that makes "credential, not assertion" real; the enterprise shape is named |
| 2026-09-13 | Denials degrade the run and are recorded as spans; never crash | Raise | The trace of a denied run must be a complete trace with a deny on it |
| 2026-09-13 | Guardrail raises `GuardrailRaisedException` under `log_guardrail_information` | `ValueError` as in the shipped example | The verdict must be a span and a 4xx |
| 2026-09-13 | NetworkPolicy on governed pods only; CNPG pods excluded | Namespace-wide | The database is not the subject and the operator manages its traffic |
| 2026-09-13 | Rate-limit demo keeps client retries (`max_retries=1`) | `max_retries=0` | Shows the control shaping a run; the refused attempts are still error spans |
| 2026-09-13 | OpenLIT `pricing_json` points at a bundled empty file | Allow the GitHub fetch | No outbound internet calls from the workload; cost is not computed here |
| 2026-09-13 | Single-machine path deferred | Build it now | Review happens on this lab; the guide marks what is lab-specific |
| 2026-09-13 | Demos run one at a time | Parallel | They share the Job name and clobber each other |

## Assumptions

- The lab's k3s enforces NetworkPolicy through its embedded controller, asynchronously
  after pod start. Measured, not assumed, but the two-second window is specific to this
  CNI.
- Cost is not demonstrated anywhere. Neither route produces a non-zero cost and the
  project's priority is attribution in tokens.
- The principal is supplied to the run, not derived from an authentication event.
- LiteLLM's in-memory cache is sufficient for rate limiting with one replica.
- The `mcp` 2.x SDK propagates baggage as well as trace context in `_meta`. Verified by
  the presence of `enduser.id` on tool-server spans, not by reading the SDK.
