"""Entry point.

`--probe` runs the throwaway single-node graph that proves the trace path.
Without it, runs the real triage graph.
"""

import sys

from .graph import build_probe_graph
from .telemetry import init_telemetry


def main() -> int:
    # Before anything else: instrumentation has to be in place before the
    # libraries it patches get used.
    init_telemetry()

    if "--probe" in sys.argv:
        result = build_probe_graph().invoke(
            {"question": "Reply with the single word: pong", "answer": ""}
        )
        print(f"probe answer: {result['answer']!r}")
        return 0

    from .triage_graph import build_triage_graph

    incident = " ".join(a for a in sys.argv[1:] if not a.startswith("-")) or (
        "Latency on the checkout service tripled in the last hour."
    )
    result = build_triage_graph().invoke(
        {"incident": incident, "evidence": [], "hypothesis": "", "report": ""}
    )
    print(result["report"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
