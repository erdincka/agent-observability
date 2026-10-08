# Governance matrix

The four audit questions, and for each: the control that answers it, where that control
is enforced, what evidence lands in the stored trace, and where the answer is still "no".
This is the page to check a deployment against. Status as of 2026-10-08, the project's
conclusion; last verified on the single-VM rebuild of 2026-10-05.

Legend: **yes** proven by a probe or a query against the store; **partial** answerable,
with a documented gap; **no** not answerable today.

## What did the agent do?

| Sub-question | Control / mechanism | Enforced at | Evidence in the trace | Status | Gap |
| :- | :- | :- | :- | :- | :- |
| Which agents ran, in what order | OpenLIT LangGraph instrumentation | SDK | `invoke_workflow`, `invoke_agent <name>`, `gen_ai.agent.name` | yes | Span leak dropped the agent → model link until guarded locally. CONTRIBUTIONS 7 |
| Which model calls, by which agent | Per-agent spans owned by the workflow | Application code | `gen_ai.operation.name=invoke_agent`, `gen_ai.agent.name`, usage, calls, finish reasons | yes | Runs before 2026-09-13 carry local names only |
| Which model actually served the call | Gateway OTel v2 | Gateway | `litellm.provider.model` | partial | Portable `gen_ai.response.model` carries the alias. CONTRIBUTIONS 3 |
| Which tools were called | `mcp` SDK server-side spans | Tool server | `tools/call <name>`, `gen_ai.tool.name` | yes | OpenLIT's client spans omit the name and double-count. CONTRIBUTIONS 10 |
| Tokens consumed, per agent and route | Agent spans plus gateway spans | Application, gateway | `gen_ai.usage.input_tokens` / `output_tokens` | yes | Summed across layers they double. CONTRIBUTIONS 5 |
| Reasoning used, and how much | Agent spans, from LangChain usage metadata | Application | `gen_ai.usage.reasoning.output_tokens` | partial | Gateway emits none; `output_tokens` excludes it. CONTRIBUTIONS 9. Reasoning *requested* not recorded anywhere |
| Outcome: usable, truncated, empty, degraded | Agent spans | Application | `triage.outcome`, `triage.degraded_reason`, `triage.unreachable_servers` | yes | Local vocabulary; the conventions have no outcome attribute |
| Was it repeated, and did it vary | Run span with run id, incident, route, image | Application | `triage_run` attributes; `gen_ai.conversation.id` from the checkpointer thread id | yes | Baseline is a distribution; no comparison tooling yet. Chapter 9 |
| Duration | Every span | All | `Duration` | yes | |

## On whose behalf?

| Sub-question | Control / mechanism | Enforced at | Evidence in the trace | Status | Gap |
| :- | :- | :- | :- | :- | :- |
| Which credential made the model call | Per-agent virtual key | Gateway | `litellm.api_key.hash`, `litellm.metadata.user_api_key_alias` | yes | |
| Which agent, as an identity the gateway can enforce on | Virtual keys per agent, team `triage` | Gateway | key alias `agent-<name>`, `litellm.team.alias` | yes | Gateway does not set `gen_ai.agent.name`; the alias is the join |
| Which human or system principal | Baggage → `BaggageSpanProcessor`; OpenAI `user` → gateway end-user promotion | Application, tool servers, gateway | `enduser.id` on every workflow and tool span; `litellm.end_user.id` on gateway spans | yes | Principal is asserted by the Job, not derived from an authentication event |
| Does identity survive the agent → tool hop | Baggage in JSON-RPC `_meta` (SEP-414) | Tool server | `enduser.id`, `gen_ai.agent.name`, `agent_obs.role` on server-side spans | yes | Baggage is an assertion; enforcement uses the bearer token |

## With what data access?

| Sub-question | Control / mechanism | Enforced at | Evidence in the trace | Status | Gap |
| :- | :- | :- | :- | :- | :- |
| Which tool, which backend | Tool server spans and their outbound HTTP spans | Tool server | `tools/call <name>` → `GET` | yes | |
| What the tool was asked for | A resource identifier and an argument hash, never the arguments | Tool server | `agent_obs.access.resource`, `agent_obs.access.args_sha256` on every tool span | partial | Local names; the hash is reversible for small argument spaces; the resource string carries the meaning |
| Was the tool permitted for this agent | Role→tool policy on a bearer token | Tool server | `authz.decision`, `authz.role`, `authz.tool` on every tool span; status ERROR on deny | yes | Static policy and tokens; local attribute names. The gateway's own MCP endpoint, which could hold this policy per virtual key, was not used (decisions.md, 2026-10-09) |
| Was the model permitted for this key | Model allow-list on the virtual key | Gateway | HTTP 403 on the gateway span; `triage.denied_by=gateway:model_access` on the agent span | yes | |
| Was the call within quota | rpm limit on the virtual key | Gateway | 429 spans with `error.type=ProxyException`; run duration | yes | Which key hit the limit is in the log, not on the 429 span |
| Was the content permitted to reach a model | Pre-call guardrail | Gateway | `execute_guardrail <name>` span with `litellm.guardrail.status` | yes | Only with `GuardrailRaisedException` and the logging decorator; otherwise a 500 and no span |
| Could the agent reach anything else | NetworkPolicy, default-deny egress on governed pods | Cluster | a connection that never completes; `make demo-egress-denied` | yes | First ~2 s of a pod unprotected on k3s; no span for a blocked connection |
| Was content stored anywhere | Collector `redaction` on the only write path, spans and logs; SDK and gateway settings as the first line | Collector | `redaction.masked.keys` on every touched span; `make demo-content-redacted` proves zero content with capture forced on | yes | LiteLLM's guardrail record carried prompts past `no_content` (CONTRIBUTIONS 13); only the Collector rule caught it |

## Can you prove it later?

| Sub-question | Control / mechanism | Enforced at | Evidence in the trace | Status | Gap |
| :- | :- | :- | :- | :- | :- |
| Is the trace complete | `make receipt` check 1 | Store | count of spans with a missing parent = 0 | yes | Spans only; log records and metrics are not covered |
| Do the layers agree | `make receipt` check 2 | Store | agent sums equal gateway sums | yes | Both wrong the same way would pass |
| How long is it kept | ClickHouse tiered policy and TTL; S3 archive | Store, MinIO | parts older than a day on `s3_cold`; delete after 7 years; every batch archived as OTLP JSON | yes | The archive is not object-locked |
| Which traces need a reviewer | Promotion into a restricted database after the trace completes | `make restricted-promote` | flagged traces whole in `otel_restricted`; a reader scoped to it | yes | a step that has to be scheduled, and traces are copied only once quiet for 60 s. Replaced tail sampling in the Collector, whose 45 s decision window is shorter than an agent run: a denial 0.8 s late was never copied |
| Has it been altered | Archive with versioning; per-run digest from `make receipt` | MinIO, store | versioning on; a sha256 over the stored spans, compared on the next receipt | partial | The digest lives in a local file here, not in the archive under object lock |
| Can a reviewer reproduce the checks | `scripts/receipt.sh`, eight queries over standard tables | Store | one command per run | yes | |
| Can the audit team see it without the author | Perses dashboards as code, read-only user | Perses | four provisioned dashboards, trace view from ClickHouse | yes | Panel vocabulary changes are code changes |
| Can the lab itself be rebuilt | Locked dependencies, digest-pinned bases, immutable tags, `make drift` | Repository | | yes | Full rebuild onto an empty cluster not re-run |

## Reading the matrix

At the end of phase 1 every "yes" was on the first question. After chapters 6 and 7 the
second question is answered on every span and the third has enforcement with evidence for
tools, models, quota, content and network. After chapter 8, content cannot reach
storage even when a component emits it, data access has a non-content record, flagged
traces have a store of their own, and the record outlives the hot tier. Chapter 9 packages
the reviewer's checks into one receipt per run, and chapter 10 puts the same questions on
four dashboards that live in the repository. The two "partial" rows that remain are
honest limits: a digest that should live under object lock, and tool arguments that are
content by definition.
