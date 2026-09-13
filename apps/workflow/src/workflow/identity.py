"""Who is acting, on whose behalf, and with which credential.

Three identities are in play on every action, and they are routinely conflated:

    principal   the human or system the run is for      -> `enduser.id`
    agent       which node of the graph is acting       -> `gen_ai.agent.name`
    workload    the pod Kubernetes authenticated        -> not this module's job

This module carries the first two as OpenTelemetry *baggage*, so they land on
every span in this process and, through the `mcp` SDK's `_meta` propagation
(SEP-414 reserves `baggage` alongside `traceparent`), on every span the tool
servers emit. A `BaggageSpanProcessor` on each side copies baggage entries onto
spans as attributes at span start (see telemetry.py).

The gateway gets the same facts by a different route, because it does not read
our baggage: the principal goes in the OpenAI `user` field, which LiteLLM
records as its end-user id, and the agent is identified by *which virtual key
made the call* — one key per agent, minted by `make litellm-keys`. That is the
difference between an attribute and an identity: baggage is an assertion the
caller makes about itself; the key is a credential the gateway verified.

Tool servers get a third thing: a per-role bearer token, for the same reason.
Baggage says which agent is calling; the token is what the server enforces on.
"""

from __future__ import annotations

import logging
import os
from contextlib import contextmanager
from typing import Iterator

from opentelemetry import baggage, context

from .settings import settings

log = logging.getLogger(__name__)

# Semconv attribute for the end user. Baggage keys double as attribute names,
# so they are chosen to be the names the spans should carry.
PRINCIPAL_KEY = "enduser.id"
AGENT_KEY = "gen_ai.agent.name"
ROLE_KEY = "agent_obs.role"

PRINCIPAL = os.getenv("PRINCIPAL", "oncall-engineer")
AGENT_ROLE = os.getenv("AGENT_ROLE", "reader")
# `per-agent` selects AGENT_KEY_<agent>. Any other value selects
# AGENT_KEY_<profile> for every agent, which is how the denial demos run all
# three agents on a deliberately restricted or throttled key.
KEY_PROFILE = os.getenv("KEY_PROFILE", "per-agent")

_warned_master = False


def gateway_key(agent: str) -> str:
    """The virtual key this agent presents to the gateway.

    Falls back to the master key from phase 1 when no per-agent key is in the
    environment, with one warning: the run still works, but every gateway span
    then says "master key" and the identity chapter is not being demonstrated.
    """
    global _warned_master
    name = agent if KEY_PROFILE == "per-agent" else KEY_PROFILE
    key = os.getenv(f"AGENT_KEY_{name}")
    if key:
        return key
    if not _warned_master:
        _warned_master = True
        log.warning(
            "no AGENT_KEY_%s in the environment — using the master key. "
            "Gateway spans will not identify the agent (run `make litellm-keys`).",
            name,
        )
    return settings.gateway_api_key


def tool_headers() -> dict[str, str]:
    """Headers for every tool call: the role's bearer token, if configured.

    Without it the tool servers treat the caller as `anonymous`, and the policy
    for anonymous is empty — every tool call is denied and the run degrades.
    That is the correct failure: an unidentified caller gets nothing.
    """
    token = os.getenv("TOOL_TOKEN")
    return {"Authorization": f"Bearer {token}"} if token else {}


@contextmanager
def acting_as(agent: str) -> Iterator[None]:
    """Put the principal, agent and role into baggage for the duration of a node.

    Attached and detached in the same task, so the detach is safe even though
    OpenLIT leaves an ended span attached in between (CONTRIBUTIONS item 7):
    resetting a ContextVar to a token restores that token's value regardless of
    what was set after it.
    """
    ctx = baggage.set_baggage(PRINCIPAL_KEY, PRINCIPAL)
    ctx = baggage.set_baggage(AGENT_KEY, agent, ctx)
    ctx = baggage.set_baggage(ROLE_KEY, AGENT_ROLE, ctx)
    token = context.attach(ctx)
    try:
        yield
    finally:
        context.detach(token)
