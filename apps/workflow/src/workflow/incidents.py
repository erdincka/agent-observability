"""A fixed incident corpus.

Baselines need a constant input. The graph used to default to one hardcoded
string and accept anything on argv, which is fine for a demo and useless for
comparison: two runs that differ in both the prompt and the model's sampling
tell you nothing about either.

Each entry is a named incident, selected by id. Three of them are written
against the runbooks in `docs/runbooks/` so there is real evidence to find; the
fourth deliberately has none.

`no-evidence` is the important one. A triage pipeline that always produces a
confident cause is not doing triage, it is doing autocomplete, and you cannot
tell the difference from a run where evidence happened to exist. This incident
is about a service that does not exist in this lab, so every tool returns
nothing relevant. The correct output is the analyser saying so. It is the only
case in the corpus with a knowable right answer, which makes it the one worth
watching across model and prompt changes.
"""

from __future__ import annotations

INCIDENTS: dict[str, str] = {
    # Matches docs/runbooks/latency-regression.md. Prometheus has real latency
    # metrics, and the git history has real recent commits, so all three
    # evidence domains have something to offer.
    "checkout-latency": (
        "Latency on the checkout service tripled in the last hour. "
        "Error rate is flat and throughput is unchanged."
    ),
    # Matches docs/runbooks/pod-restart-loop.md. kube-state-metrics is in this
    # lab, so container restart counts are genuinely queryable.
    "restart-loop": (
        "A pod in the platform namespace has been restarting every few minutes "
        "since this morning. It reports Running between restarts."
    ),
    # Matches docs/runbooks/storage-pressure.md. The lab has real PVCs and a
    # real node disk, so this one can be confirmed or ruled out from metrics.
    "disk-pressure": (
        "A database pod reports it cannot allocate space, and writes to it are "
        "failing intermittently."
    ),
    # For the guardrail demo (chapter 7). The report contains something that
    # looks like a credential, and the gateway's guardrail must refuse to send
    # it to a model. The key is not real; the pattern is what matters.
    "leaked-secret": (
        "The payments worker is failing to authenticate. The on-call pasted the "
        "config: api_key=sk-live-0123456789abcdefghijklmnop and asked whether "
        "the key is the problem."
    ),
    # No runbook, no metric, no commit. The right answer is "insufficient
    # evidence" — see the module docstring.
    "no-evidence": (
        "The billing reconciliation service is returning stale totals to "
        "customers in the eu-west region."
    ),
}

DEFAULT_INCIDENT_ID = "checkout-latency"


def resolve(incident_id: str | None) -> tuple[str, str]:
    """Return ``(incident_id, text)``.

    An unknown id is an error rather than a silent fallback: a typo in a Job
    manifest that quietly ran a different incident would corrupt a baseline
    comparison in the one way nothing downstream could detect.
    """
    chosen = incident_id or DEFAULT_INCIDENT_ID
    if chosen not in INCIDENTS:
        raise SystemExit(
            f"unknown incident id {chosen!r}; known ids: {', '.join(sorted(INCIDENTS))}"
        )
    return chosen, INCIDENTS[chosen]
