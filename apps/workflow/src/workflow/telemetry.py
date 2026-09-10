"""OpenTelemetry setup.

Deliberately the smallest possible amount of code, because everything here is a
default we are choosing not to accept.
"""

import logging

import openlit

from .settings import settings


class _DetachNoiseFilter(logging.Filter):
    """Drop one known-benign ERROR from ``opentelemetry.context``.

    Every async model call produced a stack trace in the logs:

        ERROR opentelemetry.context: Failed to detach context
        ValueError: <Token ...> was created in a different Context

    The cause is upstream and specific. OpenLIT's LangChain callback handler
    attaches an OTel context in ``on_llm_start`` and detaches it in
    ``on_llm_end`` / ``on_llm_error``
    (``openlit/instrumentation/langchain/__init__.py``, the two
    ``otel_context.detach(ctx_token)`` calls). Under an async graph those two
    callbacks fire in different asyncio Tasks, and ``contextvars`` Tokens can
    only be reset in the Context that created them — so the reset always
    raises. The handler wraps the call in ``except Exception: pass``, but that
    never sees anything: ``context_api.detach()`` swallows the ``ValueError``
    itself and logs it at ERROR before returning. The suppression is real and
    the log line is emitted anyway.

    OpenLIT already ships the correct fix and does not use it here —
    ``openlit.__helpers.safe_detach`` detaches via ``_RUNTIME_CONTEXT`` so a
    cross-Context Token becomes a DEBUG line, and its docstring describes this
    exact failure. Two call sites bypass it. Logged as CONTRIBUTIONS.md item 7.

    Filtering rather than silencing the logger: a genuine context-management
    bug elsewhere still reaches the logs. Verified harmless before suppressing
    it — the run it was loudest on produced 76 spans across five services with
    correct parenting and no error spans, because contextvars are per-Task and
    the attaching Task's context reverts when that Task ends.
    """

    def filter(self, record: logging.LogRecord) -> bool:
        return "Failed to detach context" not in record.getMessage()


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

    # After openlit.init, so the instrumentation that produces the noise is
    # already installed and the filter is the last word.
    logging.getLogger("opentelemetry.context").addFilter(_DetachNoiseFilter())
