"""A gateway guardrail: refuse to send anything that looks like a credential.

Loaded by LiteLLM from the directory of config.yaml (see `get_instance_fn`),
registered under `guardrails:` in the config, `mode: pre_call`, `default_on`.
Runs on every request before it reaches a model, and LiteLLM's OTel v2 emits
a span for it with `litellm.guardrail.*` attributes — which is the point:
policy enforcement at the gateway is itself in the trace.

Deliberately simple. The lab is not demonstrating detection quality; it is
demonstrating that a refusal at the boundary is auditable. The patterns are
the shapes of secrets, never a real one, and the exception message must not
echo the matched text, because the message reaches the caller and the trace.
"""

from __future__ import annotations

import re
from typing import Any

from litellm.exceptions import GuardrailRaisedException
from litellm.integrations.custom_guardrail import CustomGuardrail, log_guardrail_information

_SECRET_SHAPES = re.compile(
    r"(sk-(?:live|test|proj|agent)?-?[A-Za-z0-9]{16,}"      # API-key shapes
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----"                    # PEM keys
    r"|AKIA[0-9A-Z]{16}"                                      # AWS access key ids
    r"|(?i:password\s*[=:]\s*\S{8,}))"                       # password=...
)


def _texts(messages: list[dict[str, Any]] | None):
    for m in messages or []:
        c = m.get("content")
        if isinstance(c, str):
            yield c
        elif isinstance(c, list):
            for part in c:
                if isinstance(part, dict) and isinstance(part.get("text"), str):
                    yield part["text"]


class NoSecrets(CustomGuardrail):
    # The decorator is what makes the verdict observable: it records
    # StandardLoggingGuardrailInformation on the request, which OTel v2 turns
    # into a guardrail span with litellm.guardrail.* attributes. Without it, a
    # refusal is just a failed request — a 500 with no span saying why (that
    # is what the first version of this file produced).
    @log_guardrail_information
    async def async_pre_call_hook(self, user_api_key_dict, cache, data: dict, call_type):
        for text in _texts(data.get("messages")):
            m = _SECRET_SHAPES.search(text)
            if m:
                # Name the kind, never the value.
                kind = "private key" if "PRIVATE KEY" in m.group(0) else "credential-shaped string"
                # GuardrailRaisedException, not ValueError: a 400 rather than a
                # 500, and blocked_content=True tells LiteLLM the guardrail
                # reached a verdict rather than failing to run.
                raise GuardrailRaisedException(
                    guardrail_name="no-secrets",
                    message=f"request contains a {kind} and was not sent to the model",
                    status_code=400,
                    blocked_content=True,
                )
        return data
