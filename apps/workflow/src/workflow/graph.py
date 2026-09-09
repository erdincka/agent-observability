"""Scaffolding graph — a single node, one model call, no handoffs.

THIS IS THROWAWAY. Its only job is to prove that a trace starting in this
process reaches ClickHouse with the gateway's spans nested inside it. Once that
is confirmed it should be deleted, and `triage_graph.py` becomes the real entry
point.

Keeping the plumbing proof separate from the real graph is deliberate: when the
three-agent graph misbehaves, being able to run this one answers "is it my graph
or my instrumentation?" without any reasoning.
"""

from typing import TypedDict

from langchain_openai import ChatOpenAI
from langgraph.graph import END, START, StateGraph

from .settings import settings


class ProbeState(TypedDict):
    question: str
    answer: str


def _model() -> ChatOpenAI:
    """A client pointed at the gateway, never at a provider.

    `model` here is a LiteLLM *route* name, not a model name — which model
    serves it is the gateway's decision. That indirection is the entire reason
    phase 2 can add virtual keys and budgets without touching this file.
    """
    return ChatOpenAI(
        base_url=settings.gateway_base_url,
        api_key=settings.gateway_api_key,
        model=settings.model_route,
        max_tokens=64,
        timeout=300,  # CPU inference in a GPU-less lab
    )


def _answer(state: ProbeState) -> ProbeState:
    reply = _model().invoke(state["question"])
    return {"question": state["question"], "answer": reply.content}


def build_probe_graph():
    g = StateGraph(ProbeState)
    g.add_node("answer", _answer)
    g.add_edge(START, "answer")
    g.add_edge("answer", END)
    return g.compile()
