"""OpenTelemetry setup.

Deliberately the smallest possible amount of code, because everything here is a
default we are choosing not to accept.
"""

import importlib
import logging
import os
import pathlib

import openlit
from opentelemetry import trace
from opentelemetry.processor.baggage import ALLOW_ALL_BAGGAGE_KEYS, BaggageSpanProcessor

from .settings import settings

log = logging.getLogger(__name__)


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
    bug elsewhere still reaches the logs.

    Not harmless, despite first appearances. An early check found 76 spans with
    correct-looking parenting and no error spans and called this cosmetic; that
    check never looked for spans whose parent was never exported, and there were
    117 of them. The same cross-Task failure, one statement later in
    ``on_llm_end``, skips ``_end_span`` and drops the span — see
    ``_guard_langchain_span_leak`` below, which is the actual fix. This filter
    only removes the log line, and it removes the one default-visible sign that
    the failure is happening. It stays because the message is not actionable on
    its own; the guard is what makes suppressing it safe.
    """

    def filter(self, record: logging.LogRecord) -> bool:
        return "Failed to detach context" not in record.getMessage()


def _guard_langchain_span_leak() -> None:
    """Stop OpenLIT's LangChain handler from leaking the span for every model call.

    **This must run before ``openlit.init()``.** The ordering is load-bearing and
    fails silently if reversed — see the end of this docstring.

    The bug, in full, because the visible symptom is not the damage.
    ``OpenLITCallbackHandler.on_llm_end`` runs this sequence inside one ``try``
    whose handler logs at DEBUG:

        try:
            ...
            try:
                otel_context.detach(ctx_token)     # swallowed; logs ERROR
            except Exception:
                pass
            reset_framework_llm_active(fw_token)   # NOT protected
            self._end_span(run_id)                 # unreachable if that raises
        except Exception as e:
            logger.debug("Error in on_llm_end: %s", e)

    and ``openlit.__helpers.reset_framework_llm_active`` is a bare reset:

        def reset_framework_llm_active(token):
            _framework_llm_span_active.reset(token)

    A ``contextvars`` Token can only be reset in the Context that created it.
    ``on_llm_start`` and ``on_llm_end`` fire in different asyncio Tasks under an
    async graph, so this raises ``ValueError`` every time — and unlike the detach
    above it is not guarded. The outer handler logs at DEBUG, and
    ``self._end_span(run_id)`` never runs.

    An OTel span is exported when it ends. A span that never ends is never
    exported. So OpenLIT's span for each model call vanished, and with it the only
    link between an agent and its model call:

        invoke_agent retriever -> [missing] -> POST -> gateway -> chat local
             (agent name)                                         (token counts)

    Measured before this guard: 69 ``POST`` and 48 ``mcp tools/call`` spans whose
    ``ParentSpanId`` matched no row in ``otel_traces``. Both halves of the
    attribution question were present and could not be joined.

    Swallowing the ``ValueError`` leaks nothing: ``contextvars`` are per-Task, so
    the attaching Task's context reverts when that Task ends. This is what
    OpenLIT's own ``safe_detach`` already does for the OTel context, two lines
    earlier, for exactly this reason. CONTRIBUTIONS.md item 7.

    **Why before init:** ``_create_callback_handler_class()`` does a
    function-local ``from openlit.__helpers import ...`` and is called during
    ``openlit.init()``, so the handler closes over whatever the name resolves to
    at that moment. Patch after init and the closure still holds the original —
    no error, no warning, and the leak continues.
    """
    try:
        helpers = importlib.import_module("openlit.__helpers")
        original = helpers.reset_framework_llm_active
    except (ImportError, AttributeError) as exc:
        log.warning(
            "could not guard the OpenLIT span leak (%s) — agent-to-model-call "
            "attribution may be missing from traces; see CONTRIBUTIONS item 7",
            exc,
        )
        return

    def _safe(token) -> None:
        try:
            original(token)
        except ValueError:
            # Cross-Task Token. Deliberate no-op, not swallowed control flow.
            pass

    helpers.reset_framework_llm_active = _safe


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
    # Before init, not after. See the docstring — the ordering is the whole fix.
    _guard_langchain_span_leak()

    # Chapter 8's experiment: turn content capture ON, deliberately, and prove
    # the Collector strips it before storage. Never on by default; the demo
    # sets OPENLIT_CAPTURE_CONTENT=true on one run and the run says so loudly.
    capture = os.getenv("OPENLIT_CAPTURE_CONTENT", "false").lower() == "true"
    if capture:
        log.warning(
            "OPENLIT_CAPTURE_CONTENT=true: this process WILL emit prompt and "
            "completion text on its spans. The Collector's redaction is what "
            "keeps it out of the store (guide chapter 8)."
        )
    openlit.init(
        application_name=settings.service_name,
        environment=settings.environment,
        otlp_endpoint=settings.otlp_endpoint,
        capture_message_content=capture,
        # GPU and host metrics belong to the platform, not the workload, and
        # Prometheus already collects them in this lab.
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

    # After openlit.init, so the instrumentation that produces the noise is
    # already installed and the filter is the last word.
    logging.getLogger("opentelemetry.context").addFilter(_DetachNoiseFilter())

    # Identity onto every span. `identity.acting_as` puts the principal, the
    # agent and the role into baggage; this processor copies baggage onto each
    # span as attributes when the span starts. ALLOW_ALL is acceptable here
    # because this process is the only thing that writes baggage in this
    # trace; a service receiving baggage from untrusted callers should
    # allow-list the keys instead.
    provider = trace.get_tracer_provider()
    if hasattr(provider, "add_span_processor"):
        provider.add_span_processor(BaggageSpanProcessor(ALLOW_ALL_BAGGAGE_KEYS))
    else:  # pragma: no cover - only if openlit.init failed to install an SDK provider
        log.warning("no SDK tracer provider — identity baggage will not reach spans")
