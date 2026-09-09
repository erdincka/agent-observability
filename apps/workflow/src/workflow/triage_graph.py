"""The real workflow. INTENTIONALLY UNIMPLEMENTED — this one is yours.

This is the piece that carries the concepts, so writing it is the point rather
than a chore to be automated away. Everything around it — telemetry setup,
gateway client, container build, deployment, the MCP servers' transport — is
scaffolding and is already done.

---------------------------------------------------------------------------
WHAT IT SHOULD DO

One boring task: triage an incident. Three agents, genuine handoffs.

    retriever  -> gathers evidence via MCP tools
    analyser   -> forms a hypothesis from that evidence
    reporter   -> writes the summary

Three MCP servers, one per evidence domain (step 5 builds their transport):

    metrics    -> query Prometheus, already running in this lab
    changes    -> recent commits / diffs
    runbooks   -> document search

---------------------------------------------------------------------------
WHAT MAKES IT INTERESTING, AND WHY IT IS WORTH WRITING BY HAND

The handoff is the part the OTel GenAI semantic conventions have the least to
say about. A single agent calling a model is well covered — `gen_ai.operation.name`,
the usage attributes, all of it. But when `retriever` hands its findings to
`analyser`, the questions an auditor asks are:

  - Is the handoff itself a span, or just an edge between two spans?
  - What names it? There is no `gen_ai.agent.handoff` in the conventions.
  - Does "on whose behalf" survive the handoff, or does the second agent's work
    look like it originated from nowhere?

Whatever you invent here is a finding either way. If the conventions can express
it, that is worth writing up. If they cannot — which is the expectation, and is
why the brief flagged multi-agent handoffs as a contribution lane — then the
attribute names you choose are a concrete proposal to take upstream, not just a
local workaround.

So: resist reaching for a helper that hides the handoff. The seam is the subject.

---------------------------------------------------------------------------
WHAT YOU HAVE ALREADY

    from .settings import settings          # gateway URL, route name, DSN
    from .graph import _model               # gateway client; steal it
    from .telemetry import init_telemetry   # already called in __main__

    settings.postgres_dsn                   # CNPG cluster, for the checkpointer:
                                            # langgraph.checkpoint.postgres.PostgresSaver

Run the plumbing proof first — `python -m workflow --probe` — so you start from
a known-good trace path and anything that breaks afterwards is your graph.
"""

from typing import TypedDict


class TriageState(TypedDict):
    incident: str
    evidence: list[str]
    hypothesis: str
    report: str


def build_triage_graph():
    raise NotImplementedError(
        "Yours to write — see this module's docstring. "
        "Run `python -m workflow --probe` first to confirm the trace path works."
    )
