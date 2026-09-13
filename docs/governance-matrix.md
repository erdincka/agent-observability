# Governance matrix

The four audit questions, and for each: the control that answers it, where that control
is enforced, what evidence lands in the stored trace, and where the answer is still "no".
This is the page to check a deployment against. Status as of 2026-09-13, end of phase 1.

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
| Which credential made the model call | Gateway key hash | Gateway | `litellm.api_key.hash`, `litellm.metadata.user_api_key_user_id` | partial | One master key for everything. Chapter 6 |
| Which agent, as an identity the gateway can enforce on | Virtual keys per agent | Gateway | key alias, team | no | Chapter 6 |
| Which human or system principal | Baggage propagated to every span | Application, Collector | a principal attribute on every span | no | Chapter 6 |
| Does identity survive the agent → tool hop | Header on tool calls, read by the server | Tool server | principal on server-side spans | no | Chapter 6 |

## With what data access?

| Sub-question | Control / mechanism | Enforced at | Evidence in the trace | Status | Gap |
| :- | :- | :- | :- | :- | :- |
| Which tool, which backend | Tool server spans and their outbound HTTP spans | Tool server | `tools/call <name>` → `GET` | yes | |
| What the tool was asked for | Withheld: `gen_ai.tool.call.arguments` is content | Tool server | nothing | no | A non-content record of access is a design decision. Chapter 8 |
| Was the tool permitted for this agent | Per-role allow-list | Tool server | a deny decision on the span | no | Chapter 7 |
| Could the agent reach anything else | NetworkPolicy | Cluster | a connection that never completes | no | Chapter 7 |
| Was content stored anywhere | `no_content` at the gateway, `capture_message_content=False` in SDKs | Gateway, SDKs | probes grep stored values for prompt text | yes | Enforced by configuration, not by the pipeline. Chapter 8 moves it to the Collector |

## Can you prove it later?

| Sub-question | Control / mechanism | Enforced at | Evidence in the trace | Status | Gap |
| :- | :- | :- | :- | :- | :- |
| Is the trace complete | Dangling-parent query | Store | count of spans with a missing parent = 0 | yes | Manual. Chapter 9 packages it |
| Do the layers agree | Agent sums equal gateway sums | Store | per-run reconciliation | yes | Manual |
| How long is it kept | ClickHouse TTL | Store | 720 hours | partial | Retention tier not wired. Chapter 8 |
| Has it been altered | Archive with versioning, per-run digest | MinIO | none yet | no | Chapter 9 |
| Can a reviewer reproduce the checks | Queries over standard tables | Store | | partial | Not packaged. Chapter 9 |
| Can the lab itself be rebuilt | Locked dependencies, digest-pinned bases, immutable tags, `make drift` | Repository | | yes | Full rebuild onto an empty cluster not re-run |

## Reading the matrix

Nine "yes" rows, and all of them are on the first question. The three questions a data
protection officer actually asks are the ones phase 1 could not answer. That is the
expected shape at the end of "make it observable", and it is why the next chapters are
identity, authorization and content, in that order: each one turns a "no" in this table
into evidence on a span.
