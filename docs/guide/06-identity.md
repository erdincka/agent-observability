# 6. Identity: on whose behalf

**Question it answers:** on whose behalf did the agent act, which agent acted, and is that
carried through agent → tool → model so it survives handoffs and can be enforced on?
**Status:** built 2026-09-13. Phase 1 left this at "no"; every row below is now evidence
on a span.
**Tools:** LiteLLM virtual keys, teams and baggage promotion; OpenTelemetry baggage and the
baggage span processor; the `mcp` SDK's `_meta` propagation (SEP-414).

## Run

```bash
make litellm            # the gateway now promotes identity onto every span (see the env)
make litellm-keys       # one virtual key per agent, team `triage`, published as Secret agent-keys
make workflow-triage PRINCIPAL=alice     # or leave the default, oncall-engineer
```

## Look

```bash
# the gateway: which key, which team, for whom
make ch-query Q="SELECT SpanAttributes['litellm.metadata.user_api_key_alias'] AS key_alias, SpanAttributes['litellm.team.alias'] AS team, SpanAttributes['litellm.end_user.id'] AS end_user, count() FROM otel_traces WHERE TraceId='<id>' AND ServiceName='litellm-gateway' AND SpanName LIKE 'chat%' GROUP BY 1,2,3"

# the tool servers: which agent, for whom
make ch-query Q="SELECT ServiceName, SpanName, SpanAttributes['gen_ai.agent.name'] AS agent, SpanAttributes['enduser.id'] AS principal FROM otel_traces WHERE TraceId='<id>' AND ServiceName LIKE 'mcp-%' AND SpanName LIKE 'tools/call%'"
```

## What you should see

On the gateway, one row per agent, the team, and the principal:

| key_alias | team | end_user | calls |
| :- | :- | :- | -: |
| agent-retriever | triage | oncall-engineer | 5 |
| agent-analyser | triage | oncall-engineer | 1 |
| agent-reporter | triage | oncall-engineer | 1 |

On every tool server span, the agent and the principal:

```
mcp-metrics   tools/call active_alerts    agent=retriever  principal=oncall-engineer
mcp-runbooks  tools/call search_runbooks  agent=retriever  principal=oncall-engineer
```

And on the workflow's own agent spans, the same principal and the role. Counted across the
run, every span on every tool server carried the principal, and every gateway `chat` span
carried it.

## What it means

**Three identities, three carriers, and the difference between them is the chapter.**

- The **principal** ("on whose behalf") travels two ways. Into OpenTelemetry baggage, where a
  `BaggageSpanProcessor` in each process copies it onto every span as `enduser.id`; the
  `mcp` SDK forwards baggage in JSON-RPC `_meta`, so the tool servers see it without
  reading a header. And into the OpenAI `user` field, which the gateway records as its
  end-user id and promotes onto its spans.
- The **agent** is in baggage too (`gen_ai.agent.name`), so a tool server's span says which
  agent called it without walking the trace. At the gateway the agent is identified
  differently: by which virtual key made the call. That is not an attribute the caller
  wrote. It is a credential the gateway verified.
- The **role** the workflow acts in (`agent_obs.role`) is in baggage for attribution and in
  a bearer token for enforcement. Chapter 7.

**Baggage is an assertion; a key is an identity.** Anything in baggage is whatever the
caller chose to write, and SEP-414 says so in as many words: "never treat one as an
identity assertion". It is the right carrier for attribution because it is cheap and
reaches every span. It is the wrong basis for enforcement, which is why the gateway
enforces on the key and the tool servers enforce on the token, and both merely *record*
the baggage.

**The gateway's baggage promotion is off for end users by default.** LiteLLM's OTel v2
will stamp team, key hash and model onto every span out of the box, and keeps the
end-user id off unless asked, because it identifies a person. This lab turns it on
deliberately, since "on whose behalf" is one of its four questions. That is a data
protection decision, and it is made in one environment variable that an auditor can read.

**Keys are policy.** Each key carries a model allow-list and a rate limit. Chapter 7 shows
what happens when a run exceeds either.

## Where it breaks

- The gateway stamps nothing under `gen_ai.agent.name`; the key alias is the agent's
  identity there. Two vocabularies for one fact, joined by convention (`agent-<name>`).
- Identity is injected by the workflow, which knows the agent and is trusted to say so. The
  enterprise answer is injection the workflow cannot lie to: a sidecar, a signed workload
  identity, a gateway that derives the principal from the caller's token. Named here,
  not built.
- Nothing yet ties the principal to an authentication event. `oncall-engineer` is a
  string the Job was given.

## In an enterprise

A bank's data protection officer asks about the principal. A platform team budgets by
the agent. Kubernetes authenticates the workload. All three need to be on every span, and
none of them belong in a prompt. The pattern here, attribution in baggage and enforcement
on a verified credential, is the shape that survives an audit: the record says who, and
the control did not take the record's word for it.

## Read more

- `apps/workflow/src/workflow/identity.py`, whose docstring is the design.
- `scripts/litellm-keys.py` for what each key encodes; `deploy/50-litellm/litellm.yaml`
  for the promotion settings.
- LEARNINGS.md, 2026-09-13: *Phase 2, chapters 6 and 7*.
