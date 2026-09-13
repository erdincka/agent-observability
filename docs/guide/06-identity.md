# 6. Identity: on whose behalf

**Question it answers:** on whose behalf did the agent act, and is that identity carried
through agent → tool → model so it survives handoffs?
**Status:** not built. Phase 1 leaves this at **no**: every call carries the master key's
hash and a default user id, and there is no user, role or team identity anywhere.
**Tools:** LiteLLM virtual keys, teams and metadata; OpenTelemetry baggage; the MCP
servers' request headers.

## The experiment, as planned

1. **Give each agent its own credential at the gateway.** Virtual keys, minted from the
   master key and stored in the gateway's Postgres, each tagged with an agent name, a team
   and a model allow-list. The workflow's single `GATEWAY_API_KEY` becomes one per agent.
2. **Carry the human or system principal alongside.** The workflow receives "on behalf of
   whom" as an input to the run, not as text in a prompt, and sends it as end-user metadata
   on every model call and as a header on every tool call.
3. **Propagate it as trace context, not as application state.** OpenTelemetry baggage is
   the standard carrier, and MCP SEP-414 reserves `baggage` in the JSON-RPC `_meta` field
   alongside `traceparent`, so the tool hop has a defined place for it. A Collector
   processor copies selected baggage entries onto every span, so identity is on the
   gateway's span, the tool server's span and the agent's span without any of them agreeing
   on a schema. Whether the `mcp` 2.x SDK propagates baggage as well as trace context is
   the first thing to verify by reading the SDK, not by assuming.
4. **Attach a budget and a rate limit to each key.** Quota is the first governance
   decision that identity makes possible, and the gateway enforces it before the call.
   Evidence: a run that hits its budget shows a gateway span refusing the call, with no
   `chat` child, and the run degrades rather than crashes.
5. **Verify from the store.** For one run, every span across all five services carries the
   same principal, and the gateway's spans carry the agent's key alias rather than the
   master key's hash. Spend per key, as the gateway tracks it, reconciles with the token
   sums from chapter 5.

## What you should see, when built

```
triage-workflow  triage.agent retriever    principal=<who>  agent=retriever
mcp-metrics      tools/call active_alerts  principal=<who>  agent=retriever
litellm-gateway  chat local                principal=<who>  key_alias=agent-retriever  team=triage
```

## Decisions to make before building

- **Key granularity.** One virtual key per agent gives the cleanest gateway-side
  attribution and the most keys to manage. One key per workflow with the agent in metadata
  is simpler and puts trust in the caller to label itself. The lab should show one and
  discuss the other.
- **Where identity is injected.** In the workflow, which knows the agent; or at a sidecar
  or gateway, which the workflow cannot lie to. The first is what phase 2 can build; the
  second is the enterprise answer and should be named as such.
- **What the tool servers do with it.** Log it, or enforce on it. Chapter 7.

## In an enterprise

Three identities are in play and are routinely conflated: the human or system that asked,
the agent that acted, and the workload that ran it. A bank's data protection officer asks
about the first. A platform team budgets by the second. Kubernetes authenticates the third.
The audit trail needs all three on every span, and none of them belong in a prompt.

## Read more

- LEARNINGS.md: *Step 3* (the key hash and user id already on gateway spans), *The
  LiteLLM UI needs a database* (why identity lives in Postgres).
- [Governance matrix](../governance-matrix.md), row "On whose behalf".
