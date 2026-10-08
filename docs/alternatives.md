# Limitations and alternatives

What this lab could have done differently, what has moved in the ecosystem since it was
built, and what a reader could choose instead. Recorded at the project's conclusion,
2026-10-08, so that the stack here is weighed rather than copied.

The lab's own findings are in the [README](../README.md) (*Where it ended*), the
[governance matrix](governance-matrix.md) and [CONTRIBUTIONS.md](../CONTRIBUTIONS.md).
This page is the other half: for each layer, what was built, what it could not do, the
alternatives, and what each would change. Three kinds of entry are mixed here and marked
as such: a **limit of the lab's design** that could have been built another way; a **gap
in a tool** the lab chose, where another tool exists; and a **shift in the ecosystem**
since September 2026 that the project brief could not have assumed. The external facts
are dated and linked at the end. They describe the ecosystem on the date given and will
age; verify before relying on any of them.

## The short version

The four audit questions held up. Everything that worked, worked because of two
decisions: one write path into storage, and verifying what is stored instead of trusting
a setting. What did not work was mostly tooling that was younger than the questions, and
the ecosystem has since moved toward the shapes this lab had to improvise: a gateway
that sees tool traffic as well as model traffic, credential-based tool authorization in
the protocol itself, a Kubernetes-native identity for an agent, and standards bodies
asking the four questions in their own words.

| Layer | What the lab chose | Would choose today, if contribution were not the goal |
| :- | :- | :- |
| Trace store | ClickHouse via the Collector exporter | The same |
| Daily dashboards and trace view | Perses, with a trace-query plugin written for it | Grafana over the same ClickHouse, or a ClickHouse-native UI; Perses if the point is to contribute |
| Per-trace GenAI view | OpenLIT UI | A UI that reads the conventions as published, chosen by licence and content posture |
| Instrumentation | OpenLIT SDK and the `mcp` SDK | The upstream OpenTelemetry instrumentations as they mature; a library-only SDK meanwhile |
| Model gateway | LiteLLM, for model calls only | The same gateway's MCP endpoint, or one built for MCP and agent traffic, so tool calls pass a control point too |
| Tool authorization | Static bearer tokens, a ConfigMap policy | MCP's OAuth 2.1 model, a policy engine, a workload identity |
| Runtime | Plain Jobs, no isolation | A Sandbox with an identity the spans can carry |
| Content control | Deny-list redaction in the Collector | An allow-list, enforced by the pipeline and the table schema |
| Restricted store | A second database, filled by promotion | Row policies on one table, or a flag-driven second pipeline |
| Evaluation | MLflow with rule-based scores | An LLM judge from the start, joined on the trace id |

## By layer

### Trace store and trace view: ClickHouse and Perses

**Built.** The Collector writes traces, logs and metrics to ClickHouse with the stock
exporter schema. Perses provides the four dashboards as JSON in the repository and the
trace view, through the ClickHouse trace-query plugin this project wrote because none
existed ([CONTRIBUTIONS 1](../CONTRIBUTIONS.md)). The image builds the plugin from the
pull request's head commit.

**Found.** *Gap in a tool.* The plugin is unmerged, so the lab depends on a fork commit
and a beta TraceTable for a one-click trace link; a panel link to its own dashboard
needs a page reload (item 14); the time-series plugin cannot plot a string column as a
series; buckets are fixed in SQL. None of this is a fault of ClickHouse, which answered
every query in the receipt and every dashboard panel. *Limit of the design.* Choosing a
CNCF sandbox project for the audit team's daily view meant choosing to write part of it.
That was the point of the choice, and it is the first thing a reader who does not want
to contribute should change.

**Alternatives.**

- **Grafana with the ClickHouse data source plugin.** From plugin v4 the data source
  treats traces as a first-class query type: an "Use OTel" switch and a default trace
  table of `otel_traces`, a bundled Traces Explorer dashboard, and Grafana's own trace
  view. The plugin this lab wrote would not have been needed. Dashboards as code are
  mature there (JSON, jsonnet, the Grafana Operator). The trade is a larger, AGPL-licensed
  component with a UI that invites changes outside the repository, which the Perses
  chapter was written to avoid.
- **Grafana Tempo.** Trace-ID lookup from object storage, cheap to run. The lab's
  dashboards and receipt are aggregations over spans (tokens per agent, outcomes, dangling
  parents), which are block scans in Tempo and plain SQL in ClickHouse. Tempo would be a
  second store beside ClickHouse, not a replacement, and Tempo 3.0 changed its write path.
- **Jaeger v2 with its ClickHouse storage.** Jaeger promoted its ClickHouse backend from
  a feature gate to stable in v2.21.0 (September 2026). It writes its own schema, not the
  Collector exporter's, and the v2.22.0 release notes (October 2026) carry an RFC
  comparing the two. So it is a trace UI with a second set of tables on the same
  ClickHouse, fed by a second exporter from the Collector, not a reader of `otel_traces`;
  the receipt's SQL would still run against the exporter's tables.
- **A ClickHouse-native observability UI** (ClickStack/HyperDX, or SigNoz with its own
  exporter schema). One UI for logs, traces and metrics, with trace views built in. The
  cost is a second opinion about the table schema, and in SigNoz's case a second schema.

**What it would change.** Chapter 10's claim, that the audit view is a reviewed file in
the repository, survives any of these. The contribution would not have happened.

### Per-trace GenAI view and SDK: OpenLIT

**Built.** The OpenLIT UI reads the shared ClickHouse with its own collector and
database disabled. The OpenLIT SDK instruments LangGraph nodes and the MCP client; the
`mcp` SDK instruments both ends of each tool call.

**Found.** *Gaps in a tool*, seven of them (items 2, 4, 6, 7, 8, 10, 11): an undocumented
schema contract, content capture on by default against the conventions, a logs tab
shipped without its routes, a context-variable reset that leaked the span linking an
agent to its model calls, token columns that read zero for a compliant producer, doubled
and unnamed MCP client spans, and a pricing fetch from GitHub at start-up. The lab
guarded the leak locally, pointed the pricing fetch at a bundled file, and read ClickHouse
directly for everything the UI could not show.

**Alternatives.**

- **A library-only instrumentation** (OpenLLMetry, Apache 2.0) that feeds whatever store
  and UI the platform already has, with no UI opinions attached.
- **The OpenTelemetry instrumentations themselves**, as the GenAI conventions and their
  reference instrumentations mature. This removes the "two vocabularies on one hop"
  finding of chapter 4 at its source.
- **A GenAI platform UI**: Langfuse (MIT core; acquired by ClickHouse Inc. in January
  2026) or Arize Phoenix (Elastic License 2.0, OpenInference conventions). Both are built
  around prompt and completion content. Under this lab's posture most of their screens
  are empty, which is worth knowing before choosing one for a no-content deployment.

**What it would change.** Whichever SDK is chosen, chapter 3's rule stands: audit the
SDK's content default by grepping what lands in the store, not by reading its docs.

### Model gateway: LiteLLM

**Built.** Every model call passes the LiteLLM proxy. Per-agent virtual keys, a team,
model allow-lists, rate limits, a pre-call guardrail, end-user promotion onto spans,
OTel v2 attributes.

**Found.** *Gaps in a tool* (items 3, 9, 12, 13): the portable model attribute carries
the routing alias and the real model sits under a vendor key; no reasoning-token count;
a guardrail that raises the wrong exception yields a 500 and no span; a guardrail's
success record put full prompts on spans under `no_content`. *Limits of the design*: the
key that hit a rate limit is only in the log; the gateway's housekeeping writes about
1,150 spans a day with no agent running; rate limiting relies on one replica's memory.
*Limit of the design, recorded late.* The agents connect to the tool servers directly,
so the gateway saw model calls only and the tool hop had a control point on each server
and none in the middle. That was the lab's wiring, not the gateway's limit: LiteLLM
v1.100.0, the version pinned here, already ships an MCP gateway (servers declared in its
config, per-key and per-team tool access, OAuth to upstream servers, guardrails on tool
calls, cost tracking) and A2A agent endpoints. Neither was evaluated, and the omission
was noticed only at the conclusion (decisions.md, 2026-10-09).

**Alternatives.**

- **The MCP endpoint of the gateway already deployed.** The agents would call one
  endpoint with their virtual key, and chapter 7's role-to-tool policy would become the
  key's tool permissions, held where the model permissions already are. Two things read
  in the v1.100.0 source would change the lab's evidence. Its MCP span records the
  caller's `traceparent` as a span *link*, never as the parent, so a tool call lands in a
  second trace joined by a link rather than nested under the agent's span; chapter 9's
  dangling-parent check and the Gantt view would have to follow links. And it discards
  the caller's W3C baggage on purpose, because a shared gateway cannot let a client assert
  its own identity attribution. That second point is chapter 6's "credential, not
  assertion" applied harder than this lab applied it, and the best reason to run the
  experiment.
- **A gateway built for model, MCP and agent-to-agent traffic in one data plane**:
  agentgateway (Linux Foundation, now under the Agentic AI Foundation), or the Envoy
  family (Envoy AI Gateway, kgateway) on the same Gateway API the lab already uses for
  its UIs. Tool authorization becomes a gateway decision with a gateway span, and the
  "which key hit the limit" question is answered where the limit is enforced.
- **Keep LiteLLM for what it is good at**: provider breadth and the key, team and budget
  model, which the Kubernetes-native gateways were still growing in 2026.

**What it would change.** The guardrail finding (item 13) is the argument that does not
change with the gateway: any feature that logs what it saw is a content path, so the
pipeline control of chapter 8 stays whichever gateway is chosen.

### Tool access and authorization: MCP, bearer tokens, a ConfigMap

**Built.** Four MCP servers over streamable HTTP; a bearer token per role; a role-to-tool
policy in a ConfigMap; the decision, role and tool as attributes on the server's span;
a non-content record of what was accessed.

**Found.** *Limit of the design.* Tokens are static and the policy is a file. Identity in
baggage is an assertion, which chapter 6 says plainly, and enforcement is on a credential
the workflow was given. The conventions have no vocabulary for an authorization decision,
so `authz.*` is local.

**Shift since.** The MCP specification revision of 2026-07-28 makes the shape chapter 6
named the protocol's own: an MCP server is an OAuth 2.1 resource server, with protected
resource metadata (RFC 9728), resource indicators (RFC 8707) so a token minted for one
server is refused by another, Client ID Metadata Documents instead of dynamic client
registration, and an enterprise-managed authorization extension for central identity.
The protocol core became stateless in the same revision. The `mcp` 2.2.0 SDK this lab
pins predates it. MCP has been governed by the Agentic AI Foundation under the Linux
Foundation since December 2025.

**Alternatives.**

- **The OAuth 2.1 model from the specification** instead of static bearer tokens; the
  per-role token becomes a scoped token from the organisation's issuer.
- **An MCP gateway** in front of the servers, so the allow/deny decision is made once and
  recorded once, and the servers see only authorised calls. The one deployed here could
  have been it (above); a dedicated one is the other option.
- **A policy engine** (OPA Rego, Cedar) instead of the JSON file, with the same span
  attributes. The spans in chapter 7 would be identical, which was the design's point.
- **A workload identity** (SPIFFE/SPIRE, or a Sandbox's identity, below) instead of a
  Secret the Job mounts.

### Agent framework and attribution: LangGraph

**Built.** A three-agent LangGraph workflow as the specimen; per-agent spans hand-rolled
because agent names and token counts lived on different spans with no reliable join, and
because nothing recorded reasoning tokens; identity injected by the workflow; one run at a
time as a Kubernetes Job.

**Found.** *Limit of the design.* The framework is deliberately the specimen, so nothing
here is Kubernetes-native: the Job name is shared, demos run one at a time, and the
workflow is trusted to say which agent it is. *Gap in the conventions.* No handoff
vocabulary; the three handoffs in every run are state transfers nobody can see as such.

**Shift since.** Agent-to-agent communication has a protocol under neutral governance:
A2A reached v1.0 under the Linux Foundation in spring 2026. A handoff over A2A is a
request with a span, which is what the conventions still lack for in-process handoffs.
Kubernetes-native agent frameworks exist: kagent (CNCF sandbox since May 2025) declares
agents, tools and models as custom resources with OpenTelemetry tracing built in. And the
gateway this lab runs can already register and front A2A agents, which the lab did not
try.

**Alternatives.**

- **A Kubernetes-native framework** where the attribution this lab hand-rolled is the
  controller's job. The specimen stops being neutral, which matters only if the point is
  to show the telemetry independent of the framework.
- **A2A between agents** where the handoff has to be auditable across trust boundaries.
- Any framework, with the same test: the four questions are answered by what reaches
  the store, and chapter 5's query is the check.

### Runtime and isolation: "not a sandbox"

**Built.** Nothing. The lab's subject is visibility and attribution; it confines nothing,
and the README says so. NetworkPolicy is the one runtime control, and k3s leaves a pod's
first two seconds unpoliced.

**Shift since.** This is the layer that moved most. **Agent Sandbox** became a Kubernetes
SIG Apps subproject in November 2025: a Sandbox custom resource for singleton, stateful
agent runtimes, with gVisor or Kata as the isolation runtime, a stable identity, persistent
storage, and hibernate-and-resume; it reached general availability on one managed
Kubernetes service in May 2026, and other distributions pair it with hardware-assisted
isolation. **Agent Substrate**, open-sourced in May 2026 at version 0.0.0 and not yet
under any SIG or foundation, sits above it: many mostly-idle agent sessions packed onto
a small pool of pods, agents as actors separated from the workers that run them, state
snapshotted on idle and restored on another pod. Its own description says it provides no
policy enforcement, observability, authentication or audit logging, and expects a gateway
or mesh to supply them.

**What it means for this lab's questions.** The scope boundary was right: neither
project does observability, and the four questions are asked of them, not answered by
them. Two assumptions in this lab would change:

- **Identity.** Chapter 6's remaining gap is that the principal and the agent are strings
  the Job was given. A Sandbox has an identity of its own that a workload certificate can
  carry; `gen_ai.agent.id` and the enforcement credential would derive from it rather
  than from a mounted Secret.
- **One run, one process, one trace.** An actor that hibernates on one pod and resumes on
  another is still one run. Trace context and baggage have to be persisted with the
  session state and restored with it, the way this lab's checkpointer persists graph
  state, or the trace breaks at every resume and the dangling-parent query of chapter 9
  is the only thing that will say so.

Both projects were young at the date of writing: Substrate at v0.0.0, Sandbox described
by vendors as not yet production-ready for every workload. A reader building now should
still put the workflow in a Sandbox and derive identity from it; the cost is tracking two
moving projects.

### Conventions: OpenTelemetry GenAI

**Built.** Standard names wherever one existed (`gen_ai.agent.name`,
`gen_ai.usage.reasoning.output_tokens`, `gen_ai.tool.name`), local names flagged as local
where none did (`triage.outcome`, `authz.*`, `agent_obs.access.*`).

**Found.** *Gaps in the conventions*, five of them: nothing marks a gateway's span as an
intermediary's view of a call the client also reports, so tokens double across layers
(item 5); no handoff; no authorization decision; no outcome; no data-access descriptor
short of the arguments, which are content.

**Shift since.** The GenAI conventions moved out of the main semantic-conventions
repository into `open-telemetry/semantic-conventions-genai` in June 2026, with MCP
conventions alongside them. At the date of writing every GenAI document there is marked
Development and the repository has no release. Pin the convention version, expect
renames, and keep the queries that read vendor attributes saying so, as chapter 2's do.

**Alternatives.** None that avoid the problem. The local vocabularies here are candidates
for proposals, in the order the phase 2 write-up gives: the intermediary marker first,
because it is the one that corrupts a number.

### Content posture, redaction and the restricted store

**Built.** Content capture off at the SDK and the gateway; a redaction processor on the
Collector masking nine key patterns on spans and logs, as the control; a resource
identifier plus an argument hash as the data-access record; flagged traces promoted,
whole, into a second database after they go quiet; every batch archived to a versioned
bucket; a seven-year TTL on the cold tier.

**Found.** *Limits of the design.* A deny-list of key patterns is a list someone
maintains, and item 13 showed that new content paths arrive with features. The hash is
reversible for a small argument space. Promotion is a step someone schedules, and it
makes the Collector no longer the only writer. The archive is versioned but not locked.
Tail sampling in the Collector could not do the job at all: it decides at a fixed offset
from a trace's first span, and an agent run outlives any window (LEARNINGS, 2026-09-27).

**Alternatives.**

- **An allow-list instead of a deny-list.** Drop every attribute not on a list the
  platform owns, in the Collector (`transform` or `attributes` processors, or the
  `redaction` processor's allowed-keys mode) and again at the table: a schema whose
  attribute map is populated by a materialized view that only copies allowed keys. Then a
  component that starts emitting content has nowhere for it to land.
- **Classification at the emitter**, as an attribute saying what the span may contain,
  checked by the pipeline. The record then says what was permitted, not only what was
  masked.
- **Row policies in ClickHouse** on the one `otel_traces` table, so the restricted reader
  sees flagged traces and nothing else, instead of a second database and a copy. One
  writer again, and nothing to schedule.
- **Object lock from day one**, with the receipt's digest written beside the batch it
  covers.

### Evaluation: MLflow

**Built.** Rule-based scores over the reporter's one paragraph, one MLflow run per triage
run, joined on the run id and the trace id. Deliberately small.

**Found.** *Limit of the design.* The scorer counts and cannot judge relevance; the
local 3B model was wrong on most incidents while every outcome read `ok`, which is the
lab's clearest single finding: the outcome column measures the machinery, and no attribute
derived from mechanics will ever say "fluent, confident and wrong" (LEARNINGS,
2026-09-27). The evaluation drives the Job one incident at a time.

**Alternatives.** An LLM judge on the remote route against the same `correct` metric;
MLflow 3's own GenAI scorers rather than the bare run API; Phoenix or Langfuse
evaluations if one of them is the UI. In every case the join that matters is the one the
lab kept: the same run id and trace id in the score and in the receipt.

### Platform and reproducibility

**Built.** Two shapes, a three-node cluster and a single VM on a Proxmox host, with every
lab-specific value in `.env`; MinIO on a VM outside the cluster; images tagged by the last
commit that touched them; a drift check; a teardown that was run and a rebuild onto an
empty machine that was run.

**Found.** *Limits of the design.* The single-machine path still needs a hypervisor. A
history rewrite renames every image. The cold tier is not a backup. The demos share a Job
name. And an upstream shift that cost a morning: MinIO's download host went away, its
client image left Docker Hub, and its newest release shipped no binaries, so the lab now
builds its own client image from a pinned binary.

**Alternatives.** A k3d path for laptops. Any S3-compatible store with versioning and
four buckets (the lab needs nothing MinIO-specific); a cloud bucket is the honest
enterprise shape for the durable tier anyway. A ClickHouse with replicas if the store has
to survive a node, which here it does not.

## How agents are being governed, as of October 2026

The four questions were the lab's own framing in September 2026. Since then they have
been asked by standards bodies and regulators in their own words. None of the following
is a binding agent-specific rulebook at the date of writing; together they are the
vocabulary an audit committee will use, and each maps onto the questions.

| Source | What it is | Which questions it asks |
| :- | :- | :- |
| OWASP Top 10 for Agentic Applications (December 2025) | A risk list: goal hijack, tool misuse, identity and privilege abuse, inter-agent communication, cascading failures, among others | On whose behalf (identity), with what data access (tool misuse), can you prove it (traceability) |
| NIST AI Agent Standards Initiative (CAISI, February 2026) | Three tracks: industry standards, open protocols, research on agent security and identity. Preceded by the NCCoE concept paper on agent identity and the draft Cybersecurity Framework Profile for AI (NIST IR 8596, December 2025) | On whose behalf, first; the NCCoE paper's premise is that agents run as generic service accounts with no identity of their own |
| EU AI Act | No agent category; agents fall under the existing risk tiers by intended purpose. General-purpose model obligations apply since August 2025; the Digital Omnibus agreed in 2026 defers stand-alone high-risk obligations to December 2027 and embedded ones to August 2028, pending publication | Can you prove it later: the record-keeping and logging duties on high-risk systems are what chapter 9 is for |
| Cloud Security Alliance | Research notes on the agent governance gap and the AI Controls Matrix (2026) | All four, as control objectives |
| Agent governance toolkits in the framework (one open-source example, April 2026) | A policy engine in front of every agent action (YAML, Rego or Cedar), agent identities, compliance grading against the OWASP list; adapters for LangGraph among others | With what data access, enforced in-process rather than at a gateway |
| Protocol governance | MCP to the Agentic AI Foundation (December 2025); A2A to the Linux Foundation (June 2025), v1.0 in 2026; agentgateway to the same foundation | The hops this lab instruments now have neutral owners |

What changed is not the questions but who asks them and where the controls are expected
to sit. This lab enforces at two places, the gateway and the pipeline, and records at a
third, the tool server. The 2026 shape adds two more: a policy engine inside the agent
process, and a sandbox around it. The evidence an auditor wants is the same at all five,
and the receipt of chapter 9 is indifferent to where a span was made.

## If starting again today

Not a prescription; the list a reader can weigh.

**Keep.** One write path into storage. Verify by querying the store, never by reading a
setting. Denials as spans, never as crashes. Identity in baggage for attribution and on
a credential for enforcement. Dashboards and policies as files in the repository. The
receipt. The separation between "what did it do" and "was it right".

**Change.** A dashboard tool that reads ClickHouse traces without a plugin, unless
contributing is the goal. Tool calls through a gateway too, starting with the MCP endpoint
of the one already deployed. The
MCP specification's own authorization instead of bearer tokens. The workflow inside a
Sandbox, with the agent's identity derived from it. An allow-list for attributes, enforced
by the pipeline and the table. Object lock on the archive from the first day. An LLM judge
from the first evaluation.

**Watch.** A release of the GenAI conventions; the Perses pull request; Agent Substrate
finding a home; the NIST initiative's outputs; publication of the EU Omnibus; whether the
upstream instrumentations make the vendor SDKs unnecessary.

## Sources

Dated at the time they were read, 2026-10-08. Several are vendor blogs and say so; the
claims above are limited to what more than one source agreed on.

- Agent Sandbox: [Running Agents on Kubernetes with Agent Sandbox](https://kubernetes.io/blog/2026/03/20/running-agents-on-kubernetes-with-agent-sandbox), Kubernetes blog, 2026-03-20; project site at agent-sandbox.sigs.k8s.io.
- Agent Substrate: [How Google Agent Substrate works](https://www.solo.io/topics/ai-infrastructure/how-google-agent-substrate-works) (vendor); [Agent Substrate: zero-idle Kubernetes for stateful AI agents](https://www.fratepietro.com/2026/agent-substrate-zero-idle-kubernetes/).
- kagent: [CNCF project page](https://www.cncf.io/projects/kagent/).
- LiteLLM MCP gateway and A2A endpoints at the pinned version: the [v1.100.0 release notes](https://github.com/BerriAI/litellm/releases/tag/v1.100.0) (2026-09-06), including [BerriAI/litellm#38317](https://github.com/BerriAI/litellm/pull/38317), which anchors MCP tool-call spans to the gateway's own trace and links the client's context; the source tree at that tag, `litellm/proxy/_experimental/mcp_server/` (`server.py`, `_mcp_meta_trace_carrier`) and `litellm/proxy/a2a/`; current docs at [docs.litellm.ai/docs/mcp](https://docs.litellm.ai/docs/mcp).
- agentgateway: [Linux Foundation announcement](https://linuxfoundation.org/press/linux-foundation-welcomes-agentgateway-project-to-accelerate-ai-agent-adoption-while-maintaining-security-observability-and-governance); [Designing agentgateway](https://aaif.io/blog/designing-agentgateway-a-unified-high-performance-gateway-for-ai-and-api-traffic) (Agentic AI Foundation).
- MCP 2026-07-28 revision: [MCP in the enterprise: specification 2026-07-28 and security](https://wz-it.com/en/knowledge/ki/mcp-model-context-protocol/); [MCP authorization spec 2026-07-28: what changed](https://ssojet.com/blog/mcp-authorization-spec-2026-07-28-what-changed) (vendor). Primary: the specification and changelog at modelcontextprotocol.io.
- A2A: [Linux Foundation launches the Agent2Agent protocol project](https://linuxfoundation.org/press/linux-foundation-launches-the-agent2agent-protocol-project-to-enable-secure-intelligent-communication-between-ai-agents), 2025-06-23.
- GenAI conventions: [open-telemetry/semantic-conventions-genai](https://github.com/open-telemetry/semantic-conventions-genai); [status survey, July 2026](https://dev.to/azena-ai/opentelemetrys-genai-semantic-conventions-are-not-stable-yet-heres-what-actually-shipped-in-2026-3mke).
- Grafana ClickHouse data source: [ClickHouse OpenTelemetry dashboards](https://grafana.com/docs/plugins/grafana-clickhouse-datasource/latest/dashboards/); [Configuring the ClickHouse data source](https://clickhouse.com/docs/integrations/grafana/config).
- Jaeger: [ClickHouse storage](https://www.jaegertracing.io/docs/2.19/storage/clickhouse/) (2.19 docs); [v2.21.0](https://github.com/jaegertracing/jaeger/releases/tag/v2.21.0) (2026-09-14, feature gate promoted to stable) and [v2.22.0](https://github.com/jaegertracing/jaeger/releases/tag/v2.22.0) (2026-10-06) release notes.
- Langfuse: [ClickHouse welcomes Langfuse](https://clickhouse.com/blog/clickhouse-acquires-langfuse-open-source-llm-observability), 2026-01-16.
- OWASP: [Top 10 for Agentic AI Applications](https://www.f5.com/glossary/owasp-top-10-for-agentic-ai-applications) (summary; primary at genai.owasp.org).
- NIST: [CSA research note on the AI Agent Standards Initiative](https://labs.cloudsecurityalliance.org/research/csa-research-note-nist-ai-agent-standards-regulatory-framewo/); primary at nist.gov/caisi.
- EU AI Act Omnibus: [Gibson Dunn, EU AI Act Omnibus agreement](https://www.gibsondunn.com/eu-ai-act-omnibus-agreement-postponed-high-risk-deadlines/); [DLA Piper, the Digital AI Omnibus](https://knowledge.dlapiper.com/dlapiperknowledge/globalemploymentlatestdevelopments/2026/The-Digital-AI-Omnibus-Proposed-deferral-of-high-risk-AI-obligations-under-the-AI-Act).
- Agent governance toolkit: [Microsoft releases open-source toolkit to govern autonomous AI agents](https://helpnetsecurity.com/2026/04/03/microsoft-ai-agent-governance-toolkit), 2026-04-03.
