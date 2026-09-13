"""Instrumentation for the MCP servers.

Same content posture as the workflow: `capture_message_content=False` is explicit
because the OpenLIT SDK defaults it to True. See CONTRIBUTIONS.md item 4.

Tool servers arguably matter more than the workflow here. A tool call's arguments
are the *data access* half of the audit question — "with what data access" — and
they are far more likely to contain identifiers, account numbers or query
predicates than a chat prompt is.
"""

import os
import pathlib

import openlit
from opentelemetry import trace
from opentelemetry.processor.baggage import BaggageSpanProcessor


# The baggage keys a tool server will copy onto its spans. An allow-list, not
# ALLOW_ALL, because baggage is client-supplied: a caller can put anything in
# `_meta`, and only these three are worth stamping. The values are still the
# caller's assertions; the bearer token is what authorization trusts.
IDENTITY_BAGGAGE = frozenset({"enduser.id", "gen_ai.agent.name", "agent_obs.role"})


def init_telemetry(service_name: str) -> None:
    openlit.init(
        application_name=service_name,
        environment=os.getenv("DEPLOY_ENVIRONMENT", "lab"),
        otlp_endpoint=os.getenv(
            "OTLP_ENDPOINT",
            "http://otel-collector.agent-obs-platform.svc.cluster.local:4318",
        ),
        capture_message_content=False,
        collect_gpu_stats=False,
        collect_system_metrics=False,
        # Without this, openlit.init() fetches a pricing table from
        # raw.githubusercontent.com — an outbound internet call at startup
        # from a workload that is not supposed to make any, and an ERROR log
        # line under the egress policy that blocks it. An empty local table:
        # this lab does not compute cost (LEARNINGS, 2026-09-09) and the
        # gateway reports usage anyway. CONTRIBUTIONS item 11.
        pricing_json=str(pathlib.Path(__file__).with_name("pricing.json")),
    )
    provider = trace.get_tracer_provider()
    if hasattr(provider, "add_span_processor"):
        provider.add_span_processor(
            BaggageSpanProcessor(lambda key: key in IDENTITY_BAGGAGE)
        )
