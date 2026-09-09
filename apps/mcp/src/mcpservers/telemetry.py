"""Instrumentation for the MCP servers.

Same content posture as the workflow: `capture_message_content=False` is explicit
because the OpenLIT SDK defaults it to True. See CONTRIBUTIONS.md item 4.

Tool servers arguably matter more than the workflow here. A tool call's arguments
are the *data access* half of the audit question — "with what data access" — and
they are far more likely to contain identifiers, account numbers or query
predicates than a chat prompt is.
"""

import os

import openlit


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
    )
