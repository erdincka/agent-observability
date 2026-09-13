# 7. Authorization: what was it allowed to do

**Question it answers:** what tools, models and network paths was each agent permitted
to use, and what does a **denied** action look like in the trace?
**Status:** not built. Today every agent can reach every tool and every route, and all
three tools are read-only, so there is nothing to deny.
**Tools:** Kubernetes NetworkPolicy, LiteLLM model access per key, a per-role allow-list
in the MCP servers.

## The experiment, as planned

1. **Add one deliberately risky tool.** Something that changes state, for example scaling
   a deployment or writing a file, on a fourth tool server. Its existence is what makes
   authorization observable.
2. **Enforce at three layers, and show each one's evidence.**
   - **Network.** NetworkPolicy in the app namespace: the workflow may reach the gateway
     and the tool servers and nothing else; each tool server may reach only its backend.
     Evidence: a connection that never happens, visible as a client span with an error
     and no server span.
   - **Model.** Each agent's virtual key lists the routes it may use. Evidence: a gateway
     span with an auth failure and no `chat` child.
   - **Tool.** The tool server checks the caller's identity from chapter 6 against a
     per-role allow-list before running the tool. Evidence: a server-side `tools/call`
     span with error status and a reason attribute, and no downstream span.
3. **Add one guardrail at the gateway**, so that policy enforcement on content is itself
   a span. LiteLLM's guardrails emit their own spans; the point is not the guardrail's
   quality but that its decision lands in the trace beside the call it judged.
4. **Run the same incident with a role that is allowed and one that is not**, and diff
   the traces. The denial must appear as a degraded run, not a crashed one, which is why
   TODO item 1 has to be fixed first.

## What you should see, when built

```
triage-workflow  MCP send tools/call scale_deployment   status=ERROR
  mcp-ops        tools/call scale_deployment            status=ERROR  authz.decision=deny  authz.role=reader
```

and the run completing with the evidence it was allowed to gather.

## Decisions to make before building

- **Where the allow-list lives.** In the tool server's config, in a ConfigMap per role, or
  in an external policy engine. The lab should use the simplest thing that produces the
  right span, and name the enterprise option.
- **What a denial records.** The decision, the role, and the rule. Never the arguments.

## In an enterprise

A denial is evidence. An authorization layer that refuses silently produces an audit trail
indistinguishable from an agent that never tried. The span with `deny` on it is the
control proving it was applied.

Least privilege per agent, not per application. The retriever needs to read metrics; the
reporter needs nothing but a model. A single credential shared by three agents makes
"which agent tried to scale the deployment" unanswerable.

## Read more

- `deploy/00-namespace/namespaces.yaml`, whose comment drew the boundary this chapter
  enforces along.
- [Governance matrix](../governance-matrix.md), row "With what data access".
