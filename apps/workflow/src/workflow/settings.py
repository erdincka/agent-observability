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

    otlp_endpoint: str = os.getenv(
        "OTLP_ENDPOINT", "http://otel-collector.agent-obs-platform.svc.cluster.local:4318"
    )
    service_name: str = os.getenv("OTEL_SERVICE_NAME", "triage-workflow")
    environment: str = os.getenv("DEPLOY_ENVIRONMENT", "lab")

    postgres_dsn: str = os.getenv("POSTGRES_DSN", "")


settings = Settings()
