"""One boring task: triage an incident. Three agents, genuine handoffs.

    retriever  -> gathers evidence via MCP tools
    analyser   -> forms a hypothesis from that evidence
    reporter   -> writes the summary

Three MCP servers, one per evidence domain, reached over streamable HTTP:

    metrics    -> query Prometheus, already running in this lab
    changes    -> recent commits / diffs
    runbooks   -> document search

The topology is deliberately fixed — no router, no conditional edges. The only
loop in the graph is the retriever's own tool loop, and that loop is written out
here rather than hidden inside a prebuilt agent, because its iterations are
exactly what the telemetry is supposed to show.

Evidence is the raw tool output, not the retriever's prose about it. "Do not
make up evidence" is then a property of the code rather than a request in a
prompt: the model chooses which tools to call, and the servers decide what the
evidence says.

---------------------------------------------------------------------------
WHICH TOOLS GET CALLED IS THE MODEL'S DECISION, AND IT VARIES

Deliberate, and the more realistic of the two options. The alternative was to
sweep the three broad tools unconditionally before the loop and let the model
only do follow-ups, which makes coverage deterministic at the cost of deleting
tool selection as an observable — the agent would no longer be deciding
anything, and a lab built to watch agents decide things would have nothing to
watch.

The consequence is measured, not assumed. Two runs of the identical prompt
against the same Ollama pod, with `temperature=0` and `seed=1337` both confirmed
present on the gateway's spans:

    round   input tokens   run A        run B
    1       696            tool call    tool call
    2       1109           tool call    tool call
    3       1435           tool call    stopped

Same 1435-token input, different decision. Run A gathered four evidence items
across all three domains; run B gathered two, both from `metrics`. Not context
truncation — qwen2.5:3b has a 32k window and nothing came close. It is
floating-point non-associativity in llama.cpp's CPU reduction order, which
shifts with thread count and batch split. `temperature=0` plus a seed pins what
the *sampler* does; it does not make the logits bit-identical.

So "the baseline" here is a distribution over runs, not a golden trace. The
things worth tracking across N runs are domains covered, tool calls made,
evidence items gathered and total tokens — all of which are already in the
spans. A single run is an anecdote. See LEARNINGS.md, 2026-09-10.
"""

from __future__ import annotations

import json
import logging
from typing import Any, TypedDict

from langchain_core.messages import (
    AIMessage,
    BaseMessage,
    HumanMessage,
    SystemMessage,
    ToolMessage,
)
from langchain_openai import ChatOpenAI
from langgraph.graph import END, START, StateGraph

from .mcp_client import tool_belt
from .settings import settings

log = logging.getLogger(__name__)


class TriageState(TypedDict):
    incident: str
    evidence: list[str]
    hypothesis: str
    report: str


def _model(max_tokens: int) -> ChatOpenAI:
    """A client pointed at the gateway, never at a provider.

    `model` is a LiteLLM *route* name; which model serves it is the gateway's
    decision. `max_tokens` is per role on purpose — the probe graph's 64 was
    sized for the word "pong" and truncates a report mid-sentence — and the
    budgets live in settings because a reasoning route needs several times what
    a 3B route does. See `Settings.analyser_max_tokens`.
    """
    return ChatOpenAI(
        base_url=settings.gateway_base_url,
        api_key=settings.gateway_api_key,
        model=settings.model_route,
        temperature=settings.temperature,
        seed=settings.seed,
        max_tokens=max_tokens,
        timeout=300,  # CPU inference in a GPU-less lab
    )


def _text(message: BaseMessage, node: str = "?") -> str:
    """Flatten message content, warning if the model was cut off mid-answer.

    The truncation check is the important half. On a reasoning route the model
    spends its budget thinking before it writes, and when `max_tokens` runs out
    first the provider returns `finish_reason: "length"` and puts the partial
    *reasoning* into `content`. That text is fluent, plausible, and not an
    answer — and it flows into the next node as though it were one.

    Nothing downstream can tell the difference, which is the failure shape this
    project exists to make visible: an empty result is obvious, a confident
    wrong-shaped result is not. So it is said out loud here, and the marker
    reaches the next node's prompt too.
    """
    finish = (message.response_metadata or {}).get("finish_reason")
    if finish == "length":
        log.warning(
            "%s was truncated at the token cap (finish_reason=length) — its "
            "output is the model's partial reasoning, not an answer. Raise the "
            "budget for this route (see Settings.%s_max_tokens).",
            node,
            node,
        )

    content = message.content
    if isinstance(content, str):
        text = content.strip()
    else:
        text = "".join(
            block.get("text", "") if isinstance(block, dict) else str(block)
            for block in content
        ).strip()

    if finish == "length":
        text = f"[TRUNCATED at the token cap — incomplete]\n{text}"
    return text


def _render_evidence(evidence: list[str]) -> str:
    """Full evidence, for the analyser — the node whose job is to read it."""
    if not evidence:
        return "(none — no tool returned any evidence)"
    return "\n\n".join(f"[{i}] {item}" for i, item in enumerate(evidence, 1))


# One line per item: which tool, with which arguments, and how much it returned.
EVIDENCE_INDEX_CHARS = 160


def _render_evidence_index(evidence: list[str]) -> str:
    """A compact index of the evidence, for the reporter.

    The reporter's job is to format the analyser's hypothesis, not to re-read
    several KB of raw JSON — the analyser has already done that. Handing it the
    full payloads was costing real money and real failures: on the reasoning
    route the reporter spent over 4096 tokens thinking about evidence it did not
    need, ran out mid-thought, and emitted its scratchpad as the report.

    `reasoning_effort="low"` does not help (measured: 1429 reasoning tokens
    against 1143 without it, so either the provider drops the parameter or the
    model ignores it). Input size is the lever that actually moves.
    """
    if not evidence:
        return "(none — no tool returned any evidence)"
    lines = []
    for i, item in enumerate(evidence, 1):
        call, _, body = item.partition("\n")
        body = " ".join(body.split())
        if len(body) > EVIDENCE_INDEX_CHARS:
            body = body[:EVIDENCE_INDEX_CHARS] + f"... ({len(item)} chars total)"
        lines.append(f"[{i}] {call} -> {body or '(empty)'}")
    return "\n".join(lines)


# --------------------------------------------------------------------- nodes --

_RETRIEVER_SYSTEM = """\
You are the retriever in an incident triage pipeline. You gather evidence; you \
do not diagnose and you do not write prose.

Three evidence domains are available through your tools:
  metrics   - live Prometheus: firing alerts, metric names, instant PromQL
  changes   - this system's git history: recent commits, diffs, changed files
  runbooks  - written procedures for known failure modes

Call at least one tool in each of the three domains before you stop. Prefer the \
broad, cheap tools first (firing alerts, recent commits, the runbook list), then \
follow up on anything that looks related to the incident.

When you have covered all three domains, reply with the single word DONE and \
nothing else. Do not summarise what you found — the tool results are recorded \
directly and your summary would be discarded."""

_ANALYSER_SYSTEM = """\
You are the analyser in an incident triage pipeline. You are given an incident \
report and a numbered list of raw evidence gathered from monitoring, version \
control and runbooks.

State the single most likely cause, and say which numbered evidence items \
support it. If the evidence does not support any cause, say so plainly and name \
what is missing — do not invent a cause to fill the gap, and do not cite \
evidence that is not in the list.

Be brief: at most one short paragraph."""

_REPORTER_SYSTEM = """\
Write an incident summary for an on-call engineer, in exactly four sections:

SUMMARY
LIKELY CAUSE
EVIDENCE
NEXT STEP

The analyser's hypothesis is the LIKELY CAUSE — restate it plainly. The evidence
index gives one line per item; cite items by number in EVIDENCE. If the
hypothesis says the evidence is insufficient, say that as the likely cause and
make NEXT STEP the thing that would close the gap.

Write the four sections and stop."""


# Deliberately plain. The earlier version told the model to "add nothing that is
# not in the hypothesis or the evidence", which on a reasoning route produced
# paragraphs of deliberation about whether each candidate sentence complied —
# over 4096 tokens of it, so the node truncated and emitted the deliberation as
# the report. The constraint was doing the opposite of its job: inviting the
# model to reason about the rule instead of following it. Grounding is better
# enforced by what the node is *given* — the hypothesis and a compact index,
# nothing else — than by a prohibition in the prompt.


async def _retriever(state: TriageState) -> dict[str, Any]:
    """Gather evidence by actually executing tool calls.

    The loop is the point. A single `.invoke(..., tools=...)` returns one message
    whose `tool_calls` nobody runs; evidence stays empty and the trace shows a
    model call that decided to do something and then did not.
    """
    async with tool_belt() as belt:
        if not belt.specs:
            log.error("no tools reachable — retriever has nothing to call")
            return {
                "evidence": [
                    f"ERROR: no MCP tool server reachable ({belt.unreachable})"
                ]
            }

        model = _model(settings.retriever_max_tokens).bind_tools(belt.specs)
        messages: list[BaseMessage] = [
            SystemMessage(_RETRIEVER_SYSTEM),
            HumanMessage(f"Incident to investigate:\n\n{state['incident']}"),
        ]
        evidence: list[str] = []

        for round_no in range(1, settings.max_tool_rounds + 1):
            reply: AIMessage = await model.ainvoke(messages)
            messages.append(reply)

            if not reply.tool_calls:
                log.info("retriever stopped after %d round(s): %r", round_no, _text(reply, "retriever")[:80])
                break

            for call in reply.tool_calls:
                name, args = call["name"], call.get("args") or {}
                result = await belt.call(name, args)
                evidence.append(
                    f"{belt.server_of(name)}/{name}({json.dumps(args, default=str)})"
                    f"\n{result}"
                )
                messages.append(ToolMessage(content=result, tool_call_id=call["id"]))
        else:
            log.warning("retriever hit the %d-round cap", settings.max_tool_rounds)

        log.info("retriever gathered %d evidence item(s)", len(evidence))
        return {"evidence": evidence}


async def _analyser(state: TriageState) -> dict[str, Any]:
    """Form a hypothesis from the evidence the retriever actually collected."""
    reply = await _model(settings.analyser_max_tokens).ainvoke(
        [
            SystemMessage(_ANALYSER_SYSTEM),
            HumanMessage(
                f"Incident:\n{state['incident']}\n\n"
                f"Evidence:\n{_render_evidence(state['evidence'])}"
            ),
        ]
    )
    return {"hypothesis": _text(reply, "analyser")}


async def _reporter(state: TriageState) -> dict[str, Any]:
    """Write the summary from the hypothesis, with the evidence for citations."""
    reply = await _model(settings.reporter_max_tokens).ainvoke(
        [
            SystemMessage(_REPORTER_SYSTEM),
            HumanMessage(
                f"Incident:\n{state['incident']}\n\n"
                f"Hypothesis:\n{state['hypothesis'] or '(the analyser produced none)'}\n\n"
                f"Evidence index:\n{_render_evidence_index(state['evidence'])}"
            ),
        ]
    )
    return {"report": _text(reply, "reporter")}


def build_triage_graph(checkpointer: Any = None):
    """Compile the graph.

    `checkpointer` is optional and the graph is identical without it. Passing
    one buys two things here: the run becomes resumable under its `thread_id`,
    and OpenLIT reads that same `thread_id` out of the invoke config and stamps
    it on every node span as a conversation id — so run correlation in
    ClickHouse comes from wiring that already existed rather than from a second
    mechanism bolted alongside it.
    """
    g = StateGraph(TriageState)
    # Node names become `invoke_agent <name>` spans in OpenLIT, so they are
    # user-facing strings in ClickHouse, not just local identifiers.
    g.add_node("retriever", _retriever)
    g.add_node("analyser", _analyser)
    g.add_node("reporter", _reporter)
    g.add_edge(START, "retriever")
    g.add_edge("retriever", "analyser")
    g.add_edge("analyser", "reporter")
    g.add_edge("reporter", END)
    return g.compile(checkpointer=checkpointer)
