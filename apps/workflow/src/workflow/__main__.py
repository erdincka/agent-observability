"""Entry point.

    python -m workflow --probe                  the plumbing proof, one node
    python -m workflow                          the default incident
    python -m workflow --incident restart-loop  a named incident from the corpus
    python -m workflow --list                   what the corpus holds

Async throughout: the triage graph's retriever node talks to MCP over HTTP, and
a coroutine node under LangGraph's synchronous `.invoke()` raises
`TypeError: No synchronous function provided`. The probe graph's node is sync and
runs fine under `ainvoke` — LangGraph offloads it to a thread.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import uuid
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator

from opentelemetry import trace

from .graph import build_probe_graph
from .incidents import INCIDENTS, resolve
from .settings import settings
from .telemetry import init_telemetry

log = logging.getLogger(__name__)


@asynccontextmanager
async def _checkpointer() -> AsyncIterator[Any]:
    """A Postgres checkpointer when a DSN is configured, otherwise nothing.

    `langgraph-checkpoint-postgres` has been a dependency and POSTGRES_DSN has
    been plumbed into the Job since step 4, with nothing constructing a saver —
    dead wiring that looked like a working feature. Either use it or delete it;
    this uses it, because `thread_id` is the run-correlation key the traces were
    missing and a checkpointer is what gives a run one.

    Still optional: with no DSN the graph compiles unchecked and runs the same,
    so a local run against port-forwards needs no database.
    """
    if not settings.postgres_dsn:
        log.info("no POSTGRES_DSN — running without a checkpointer")
        yield None
        return

    from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

    async with AsyncPostgresSaver.from_conn_string(settings.postgres_dsn) as saver:
        # Idempotent, and cheap enough to run every time. Leaving it to a
        # one-off migration step means the first run on a fresh database fails
        # on a missing table, which reads as a connection problem.
        await saver.setup()
        log.info("checkpointer ready")
        yield saver


async def _run(args: argparse.Namespace) -> int:
    if args.probe:
        result = await build_probe_graph().ainvoke(
            {"question": "Reply with the single word: pong", "answer": ""}
        )
        print(f"probe answer: {result['answer']!r}")
        return 0

    incident_id, incident = resolve(args.incident)
    run_id = os.getenv("RUN_ID") or uuid.uuid4().hex[:12]

    from .triage_graph import build_triage_graph

    tracer = trace.get_tracer("workflow.triage")
    # One span wrapping the whole run, carrying what the run *was*. Without it
    # the only grouping key in ClickHouse is TraceId, and nothing on a span says
    # which incident or which image produced it — so "compare run 7 to run 12"
    # is archaeology. These four attributes make it a query.
    with tracer.start_as_current_span(
        "triage_run",
        attributes={
            "triage.run_id": run_id,
            "triage.incident_id": incident_id,
            "triage.model_route": settings.model_route,
            "triage.image": os.getenv("WORKFLOW_IMAGE", "unknown"),
        },
    ) as span:
        async with _checkpointer() as saver:
            graph = build_triage_graph(checkpointer=saver)
            result = await graph.ainvoke(
                {"incident": incident, "evidence": [], "hypothesis": "", "report": ""},
                # thread_id is the run id on purpose: it is the checkpointer's
                # key AND the conversation id OpenLIT stamps on every node span.
                config={"configurable": {"thread_id": run_id}},
            )

        # Measured here rather than derived from the trace later, so the numbers
        # the run reports and the numbers the spans report can be compared.
        span.set_attribute("triage.evidence_items", len(result["evidence"]))
        span.set_attribute(
            "triage.domains_covered",
            len({item.split("/", 1)[0] for item in result["evidence"]}),
        )

    # Printed in full because the run's value is the handoff, not just the last
    # node's output: an empty evidence list under a confident report is the
    # failure mode worth seeing in the logs, not just in the trace.
    print(f"\n=== run {run_id} | incident {incident_id} | route {settings.model_route} ===")
    print(incident)
    print(f"\n=== evidence ({len(result['evidence'])} items) ===")
    for i, item in enumerate(result["evidence"], 1):
        print(f"\n[{i}] {item}")
    print(f"\n=== hypothesis ===\n{result['hypothesis']}")
    print(f"\n=== report ===\n{result['report']}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="workflow")
    parser.add_argument("--probe", action="store_true", help="run the plumbing proof")
    parser.add_argument(
        "--incident",
        default=os.getenv("INCIDENT_ID"),
        help="incident id from the fixed corpus (see --list)",
    )
    parser.add_argument(
        "--list", action="store_true", help="list the incident corpus and exit"
    )
    args = parser.parse_args()

    if args.list:
        for key, text in sorted(INCIDENTS.items()):
            print(f"{key:18} {text}")
        return 0

    logging.basicConfig(
        level=logging.INFO, format="%(levelname)s %(name)s: %(message)s"
    )
    # Before anything else: instrumentation has to be in place before the
    # libraries it patches get used.
    init_telemetry()
    return asyncio.run(_run(args))


if __name__ == "__main__":
    raise SystemExit(main())
