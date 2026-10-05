"""Configuration, read from the environment.

Every value has a working default pointing at the in-cluster services, so the
workflow runs with no configuration at all inside the lab.
"""

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    # The workflow never talks to a model provider directly — only ever to the
    # gateway. That is what makes "who called what, on whose behalf" answerable
    # in one place, and it is why phase 2 needs no changes here.
    gateway_base_url: str = os.getenv(
        "GATEWAY_BASE_URL", "http://litellm.agent-obs-platform.svc.cluster.local:4000/v1"
    )
    gateway_api_key: str = os.getenv("GATEWAY_API_KEY", "")
    # A LiteLLM route name ("local" / "remote"), not a model name. Which model
    # that resolves to is the gateway's business, not the workflow's.
    model_route: str = os.getenv("MODEL_ROUTE", "local")

    # Sampling is pinned, not left to the provider. `temperature` unset means
    # ChatOpenAI sends nothing and Ollama applies its own default (~0.8), which
    # makes span counts, tool-call counts and token totals move run to run for
    # sampling reasons. A baseline you cannot diff is not a baseline.
    temperature: float = float(os.getenv("MODEL_TEMPERATURE", "0"))
    seed: int = int(os.getenv("MODEL_SEED", "1337"))
    # How long one model call may take before the client gives up. CPU
    # inference in a GPU-less lab: a 3B model writing to its token cap took
    # eleven minutes on a 12-vCPU VM (2026-10-05, LEARNINGS.md), where the
    # original lab's 16-core workers kept the same seeded run under five. A
    # property of the machine, so it comes from .env (MODEL_TIMEOUT).
    model_timeout: float = float(os.getenv("MODEL_TIMEOUT", "300"))

    otlp_endpoint: str = os.getenv(
        "OTLP_ENDPOINT", "http://otel-collector.agent-obs-platform.svc.cluster.local:4318"
    )
    service_name: str = os.getenv("OTEL_SERVICE_NAME", "triage-workflow")
    environment: str = os.getenv("DEPLOY_ENVIRONMENT", "lab")

    postgres_dsn: str = os.getenv("POSTGRES_DSN", "")

    service_domain: str = os.getenv("SERVICE_DOMAIN", "agent-obs-app.svc.cluster.local")
    mcp_port: int = int(os.getenv("MCP_PORT", "8080"))
    # Seconds to connect to a tool server and complete its handshake. A server
    # that black-holes must degrade the run, not hang it (TODO item 1).
    mcp_connect_timeout: float = float(os.getenv("MCP_CONNECT_TIMEOUT", "10"))

    # How many model → tool → model rounds the retriever may take before it is
    # cut off. A 3B model will happily loop; this bounds the run without
    # bounding it so tightly that it cannot reach all three domains.
    max_tool_rounds: int = int(os.getenv("MAX_TOOL_ROUNDS", "6"))

    # Per-role output budgets, deliberately generous. A reasoning model spends
    # its budget thinking before it writes anything: the `remote` route burned
    # 1545 reasoning tokens to produce a 287-character answer. Capped below
    # that, the provider returns `finish_reason: length` and puts the partial
    # reasoning into `content` — so the node's output is the model's scratchpad
    # instead of its answer, and the next node analyses that. Given room, the
    # reasoning is dropped and `content` is the answer alone.
    #
    # Costs nothing on the local route, which stops at its own stop token well
    # before the cap.
    retriever_max_tokens: int = int(os.getenv("RETRIEVER_MAX_TOKENS", "1024"))
    # 8192, not 4096: the first run with per-agent attribution showed the
    # analyser spending 4792 reasoning tokens on one call and truncating, which
    # emptied the report downstream. A cap is a ceiling, not an allocation —
    # headroom costs nothing on runs that do not use it.
    analyser_max_tokens: int = int(os.getenv("ANALYSER_MAX_TOKENS", "8192"))
    reporter_max_tokens: int = int(os.getenv("REPORTER_MAX_TOKENS", "8192"))


settings = Settings()
