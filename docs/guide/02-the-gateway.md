# 2. The gateway as a control point

**Question it answers:** which model served a request, on which key, with what usage, and
can all of that be known **without** recording the prompt?
**Status:** built.
**Tools:** LiteLLM proxy, Ollama, PostgreSQL (CloudNativePG).

## Run

```bash
make step3                          # Ollama, model pull, gateway and its database
./scripts/gateway-trace.sh local    # one call with an incoming traceparent
./scripts/gateway-trace.sh remote   # only if an external key is in .env
```

## Look

The probe sends a chat completion with a `traceparent` header it generated itself, then
waits until the span count in ClickHouse stops changing and prints the tree and the
attributes on the model-call span. It also greps every stored attribute value for the
prompt and response strings.

## What you should see

Three spans on the trace id the probe chose, the root parented on a span id that exists
only in the header it sent:

```
POST /v1/chat/completions   Server     parent = the caller's span
├─ auth /v1/chat/completions  Internal
└─ chat local                 Client
```

On the `chat` span, with no content anywhere:

```
gen_ai.operation.name          gen_ai.usage.input_tokens     litellm.cost.total
gen_ai.provider.name           gen_ai.usage.output_tokens    litellm.call_id
gen_ai.request.model           gen_ai.response.finish_reasons litellm.api_key.hash
gen_ai.response.model          gen_ai.response.id            litellm.metadata.user_api_key_user_id
litellm.provider.model         server.address / server.port
```

## What it means

**The gateway joins the caller's trace.** Its root span parents onto the incoming span id
and never starts a parallel trace. Everything in chapter 3 depends on this: the agent's
model call is inside the agent's trace with no correlation code.

**Content is off, and the probe proves it rather than trusting the setting.** `no_content`
is the default; it is set explicitly because a posture that depends on nobody changing a
default is not a posture. The grep is the evidence.

**Usage, model, provider, outcome and a key hash all survive with no content.** This is
the first concrete support for the project's claim. The key hash and user id are the seed
of "on whose behalf", which chapter 6 turns into enforceable identity.

**The gateway is stateless for routing and stateful for identity.** It served every model
call in phase 1 with no database; the moment something asked "who is logging in", it
needed one. The tables that make the UI work are the tables virtual keys, teams and budgets
live in.

## Where it breaks

- `gen_ai.response.model` reports the routing alias, `local` or `remote`, not the model
  that served the request. The real identity is only under the vendor-specific
  `litellm.provider.model`. A reader of the portable attributes cannot tell a local 3B
  model from a third-party frontier model. CONTRIBUTIONS item 3.
- The gateway emits no reasoning-token count, and its `output_tokens` excludes reasoning
  on a reasoning route. CONTRIBUTIONS item 9.
- `LITELLM_OTEL_LEGACY_COMPAT` defaults to `true`, which re-emits every attribute under a
  second vocabulary. It is off here, and chapter 5 shows what that costs in OpenLIT's UI.
- `LITELLM_SALT_KEY` defaults to the master key, which couples key rotation to the
  readability of stored provider credentials. Set separately.

## In an enterprise

The gateway is where "which model processed this request" is decidable, and that is a
compliance answer, not a technical one. A sovereign or regulated deployment needs the
portable attribute to carry the real model, because the audit tool reading it will not
know LiteLLM's private keys. Until item 3 lands upstream, any query in this guide that
needs the real model reads `litellm.provider.model` and says so.

Two operational lessons that generalise: a config value and the secret it depends on must
be applied by the same command, and the model list must have one source of truth.
`STORE_MODEL_IN_DB=false` is set so routes added through the UI cannot silently merge
with the committed config.

## Read more

- LEARNINGS.md: *Step 3* (2026-09-09), *The remote route* (2026-09-09), *A trap in the
  Makefile* (2026-09-09), *The LiteLLM UI needs a database* (2026-09-09).
- `deploy/50-litellm/litellm.yaml`, `scripts/gateway-trace.sh`.
