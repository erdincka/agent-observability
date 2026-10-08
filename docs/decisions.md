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
| 2026-09-13 | Redaction masks by key pattern on the Collector, spans and logs, with `summary: debug` | Rely on SDK and gateway settings | Both settings were honoured and content still leaked via the guardrail record; only the pipeline rule caught it |
| 2026-09-13 | Data access recorded as a per-tool resource identifier plus an argument hash | Record arguments; record nothing | Meaning without content; the hash gives identity, and is flagged as reversible for small inputs |
| 2026-09-13 | Restricted store as a second database on the same ClickHouse, fed by tail sampling; main store keeps 100 % | Sample the main store; a separate instance | A lab must stay readable; separate access control is the property being shown, not separate hardware |
| 2026-09-27 | Promote flagged traces into the restricted store after they complete (`make restricted-promote`), replacing the Collector's tail sampling | Raise `decision_wait` past the longest run; route individual spans instead of whole traces | A fixed window decides from a trace's first span, and an agent run outlives it — one denial landed 0.8 s late and was never copied. A longer window buffers every trace, delays every copy, and still fails on the next long run. Copying from the stored record also makes the restricted copy identical to it by construction |
| 2026-09-13 | Hot TTL 1 day to S3, delete at 7 years; archive every batch to a versioned bucket | Keep the exporter's 30-day delete | Two copies with different failure modes; the seven-year requirement lands somewhere real |
| 2026-09-13 | Content that reached the store before redaction was masked in place, not deleted | Delete the rows; leave them | The spans stay whole; the mask says why it is missing |
| 2026-09-13 | Debug exporter down to `basic` | Keep `detailed` | It printed attributes to the Collector's log, a second place content could land |
| 2026-09-13 | The receipt is a script of eight queries, one command per run, with a digest recorded locally | A stored report; a digest in the archive | Reviewers run checks; the archive placement is named as the enterprise shape |
| 2026-09-13 | Perses image = stock image plus the PR-built ClickHouse archive in a second directory, built from the fork at a pinned commit | Upload the local checkout; wait for the PR to merge | Reproducible from the repository; a distroless final stage cannot delete the bundled archive |
| 2026-09-13 | Dashboards as provisioned JSON in a ConfigMap; nothing created in the UI | The UI, the OCI-artifact mount, the sidecar | A diff in a pull request is the reviewable artefact; the other mechanisms are named |
| 2026-09-13 | Perses reads as `perses_reader`, SELECT only, password as a mounted file | The default user; a password in a provisioning file | Least privilege for a read path; secrets stay out of files |
| 2026-09-13 | MLflow built, small: rule-based scores, one experiment, output text stored only in MLflow | Skip it; an LLM judge | The brief asks for the loop; judgement quality is not what the lab demonstrates; content stays out of the telemetry store |
| 2026-09-13 | MLflow's database credentials read from the CNPG Secret and passed to Helm at deploy time | Literal values in a file | The chart's schema takes literals only; the release is the only place they land |
| 2026-09-13 | MLflow host validation off (`serverAllowedHosts: ["*"]`) | An explicit list | The kubelet probes present the pod IP as Host and the pod restart-looped; the gateway is the only path in |
| 2026-09-13 | MLflow on one worker with a 3 GiB limit | The chart's four workers at 2 GiB | OOM-killed before the first request |
| 2026-09-13 | Content that the evaluation must read (the hypothesis) is read from the Job's log and stored only in MLflow | Put it on a span; skip it | "Was it right" needs the output; the telemetry store stays content-free |
| 2026-10-08 | Concluded: the stack stays pinned to the versions it was tested with, and the findings, limits and alternatives are recorded in README.md and docs/alternatives.md | Keep tracking upstream releases and the Perses PR | The value is in the recorded experiments; what has moved since is a page a reader can check, not a rebuild |

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
