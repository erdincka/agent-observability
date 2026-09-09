"""OpenTelemetry setup.

Deliberately the smallest possible amount of code, because everything here is a
default we are choosing not to accept.
"""

import openlit

from .settings import settings


def init_telemetry() -> None:
    """Initialise OpenLIT's auto-instrumentation.

    Note ``capture_message_content=False``. It is not decorative and it is not
    the library default — ``openlit.init()`` defaults it to ``True``.

    This matters more than it looks. The LiteLLM gateway in front of us is
    configured for ``no_content`` and follows the GenAI semantic conventions,
    where content capture is opt-in. The OpenLIT SDK inverts that default. Left
    alone, the gateway's spans would be clean while the spans emitted from
    inside *this process* carried the full prompt and completion — into the same
    collector, into the same ClickHouse table, sitting next to each other.

    Anyone who audited the gateway and concluded content was not being stored
    would be wrong, and nothing would tell them. See CONTRIBUTIONS.md item 4.
    """
    openlit.init(
        application_name=settings.service_name,
        environment=settings.environment,
        otlp_endpoint=settings.otlp_endpoint,
        capture_message_content=False,
        # GPU and host metrics belong to the platform, not the workload, and
        # Prometheus already collects them in this lab.
        collect_gpu_stats=False,
        collect_system_metrics=False,
    )
