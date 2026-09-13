# 7. Authorization: what was it allowed to do

**Question it answers:** what tools, models, content and network paths was each agent
permitted, and what does a **denied** action look like in the trace?
**Status:** built 2026-09-13. Six controls, each with a demo whose evidence is a span.
**Tools:** the tool servers' role→tool policy and bearer tokens; LiteLLM model allow-lists,
rate limits and a custom guardrail; Kubernetes NetworkPolicy and RBAC.

## Run

Each demo is one run. Run them one at a time: they share the Job name.

```bash
make demo-tool-denied     # reader asks mcp-ops to restart a deployment: denied on the server's span
make demo-tool-allowed    # operator does the same: allowed, mcp-runbooks restarts
make demo-model-denied    # every agent on a key that may only use `remote`, run on `local`
make demo-rate-limited    # every agent on a 2 rpm key
make demo-guardrail       # an incident containing a credential-shaped string
make demo-egress-denied   # a governed pod tries Ollama directly, around the gateway
```

## Look

```bash
# tool decisions, allowed and denied, with who
make ch-query Q="SELECT ServiceName, SpanAttributes['authz.tool'] AS tool, SpanAttributes['authz.role'] AS role, SpanAttributes['authz.decision'] AS decision, SpanAttributes['enduser.id'] AS principal, StatusCode FROM otel_traces WHERE SpanAttributes['authz.decision']!='' AND Timestamp > now() - INTERVAL 1 HOUR ORDER BY Timestamp"

# gateway refusals on the agent spans
make ch-query Q="SELECT SpanAttributes['triage.run_id'] AS run, SpanAttributes['gen_ai.agent.name'] AS agent, SpanAttributes['triage.outcome'] AS outcome, SpanAttributes['triage.denied_by'] AS denied_by FROM otel_traces WHERE SpanAttributes['triage.outcome']='denied' AND Timestamp > now() - INTERVAL 1 HOUR"

# the guardrail's own spans
make ch-query Q="SELECT SpanName, StatusCode, SpanAttributes['litellm.guardrail.status'] AS verdict, SpanAttributes['litellm.metadata.user_api_key_alias'] AS key FROM otel_traces WHERE SpanAttributes['litellm.guardrail.name']!='' AND Timestamp > now() - INTERVAL 1 HOUR"
```

## What you should see

**Tool access.** The same tool, two roles, two spans on `mcp-ops`:

```
tools/call restart_deployment  authz.role=reader    authz.decision=deny   status=ERROR
tools/call restart_deployment  authz.role=operator  authz.decision=allow
```

The reader's run continues: the tool returns an error result, the evidence records it, and
nothing crashes. Every *allowed* call carries `authz.decision=allow` too, so "was this
checked?" is answerable for the calls that went through.

**Model access.** Every agent on the `restricted` key, run on the `local` route:

```
HTTP 403  key not allowed to access model. This key can only access models=['remote']
retriever  triage.outcome=denied  triage.denied_by=gateway:model_access
analyser   triage.outcome=denied  triage.denied_by=gateway:model_access
reporter   triage.outcome=denied  triage.denied_by=gateway:model_access
```

**Rate limit.** Every agent on a 2 rpm key. Three `POST /v1/chat/completions` spans on the
gateway with `error.type=ProxyException` (the 429s), the client honouring `Retry-After`, and
the run taking 304 seconds instead of about 60. The limit shaped the run rather than
ending it, which is what a rate limit is for; with `max_retries=0` it would have ended it,
with `triage.denied_by=gateway:rate_limit`.

**Guardrail.** An incident containing `api_key=sk-live-…`:

```
execute_guardrail no-secrets   status=ERROR   litellm.guardrail.status=guardrail_intervened   key=agent-retriever
HTTP 400  Guardrail raised an exception, Guardrail: no-secrets, Message: request contains a credential-shaped string
```

The guardrail's decision is its own span, next to the call it judged, on every run. On
runs it allowed, the same span says `success`.

**Network.** A pod with the governed label, three seconds after starting:

```
ollama direct, around the gateway: blocked (expected: blocked)
gateway: HTTP 200 (expected: 200)
```

## What it means

**A denial is evidence, and it has to be a span.** Each control here records its decision
where the decision was made: the tool server for tools, the gateway for models, rate and
content, the kernel for the network. The workflow records the *consequence* on its own
agent span, `triage.outcome=denied` with `triage.denied_by`, so one filter finds every run
a control touched. A control that refuses silently produces a trail indistinguishable
from an agent that never tried.

**Denials degrade, never crash.** This is why TODO item 1 had to be fixed first. A denied
tool returns an error result; a refused model call marks the node and the run goes on.
The trace of a run with a denial in it is a complete trace with a `deny` on it, not a
missing trace.

**Enforcement is on a credential, attribution is on baggage.** The tool servers decide on
the bearer token; the gateway decides on the key. Both then *record* the baggage
(`gen_ai.agent.name`, `enduser.id`) beside the decision. Chapter 6 explains why those are
different things.

**Least privilege per agent, not per application.** The reader role can read metrics,
history, runbooks and deployment status. Restarting a deployment needs the operator
role, and the RBAC on `mcp-ops` limits even that to Deployments in its own namespace.

## Where it breaks

- **The first seconds of a pod are unprotected.** k3s's embedded network policy
  controller programs a new pod's rules asynchronously. Measured: a request at +0 s
  reached Ollama, requests from +2 s on were blocked. A workload that makes its first
  outbound call immediately gets one free. The demo sleeps for three seconds; an
  enterprise deployment needs a CNI whose enforcement is synchronous with pod start, or
  an init step that waits for it.
- **A custom guardrail that raises `ValueError` produces a 500 and no guardrail span.** The
  verdict only becomes a span when the hook is wrapped in LiteLLM's
  `log_guardrail_information` and raises `GuardrailRaisedException`, which the shipped
  example does not show for pre-call. The first version of this lab's guardrail refused
  correctly and left no trace of having done so. CONTRIBUTIONS item 12.
- **Rate-limit refusals are not attributed to the agent on the gateway side.** The 429 spans
  carry the error type; which key hit the limit is in the gateway log, not on the span.
- **The role→tool policy and the tokens are static.** A ConfigMap and a Secret. The
  enterprise shape is a policy engine and a signed workload identity; the spans would be
  identical.
- **The OpenLIT SDK phones home at startup** to fetch a pricing table from GitHub. The
  egress policy blocks it, which is how it was noticed. Now pointed at a bundled file.
  CONTRIBUTIONS item 11.
- The authorization attribute names (`authz.*`, `triage.denied_by`) are local. The GenAI
  conventions have no vocabulary for a refused action.

## In an enterprise

The question an auditor asks is not "did the agent misbehave" but "could it have, and
would you know". Six controls, six spans, and a way to run each one on demand is the
answer to the second half. The first-seconds gap is the kind of finding that only shows
up by trying it, and it is worth more than the five controls that worked.

## Read more

- `apps/mcp/src/mcpservers/server_base.py` (`guard`), `deploy/80-mcp/policy.json`,
  `deploy/50-litellm/agent_obs_guardrail.py`, `deploy/85-netpol/policies.yaml`.
- LEARNINGS.md, 2026-09-13: *Phase 2, chapters 6 and 7*.
