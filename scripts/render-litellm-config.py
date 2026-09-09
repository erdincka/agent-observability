#!/usr/bin/env python3
"""Render the LiteLLM model list from .env.

The remote route is emitted only when OPENROUTER_API_KEY is actually set. That
is the mechanism behind the project's claim that nothing hosted is required:
with no key present, the gateway comes up with exactly one route, and it is the
self-hosted one.
"""
import os
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
env = {}
for line in (root / ".env").read_text().splitlines():
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()

ollama_model = env.get("OLLAMA_MODEL") or "qwen2.5:3b"
routes = [
    "  # Self-hosted route. Committed default; requires nothing external.",
    "  - model_name: local",
    "    litellm_params:",
    # ollama_chat (not ollama) — the /api/chat endpoint, which supports the
    # tool-calling the LangGraph workflow needs in step 5.
    f"      model: ollama_chat/{ollama_model}",
    "      api_base: os.environ/OLLAMA_BASE_URL",
]

openrouter_key = env.get("OPENROUTER_API_KEY", "")
openrouter_model = env.get("OPENROUTER_MODEL", "")
if openrouter_key:
    if not openrouter_model:
        sys.exit("OPENROUTER_API_KEY is set but OPENROUTER_MODEL is empty — "
                 "set the model id you want the remote route to resolve to.")
    routes += [
        "  # Optional external route. Present only because a key was supplied;",
        "  # it adds a route alongside the local one, it does not replace it.",
        "  - model_name: remote",
        "    litellm_params:",
        f"      model: openrouter/{openrouter_model}",
        "      api_key: os.environ/OPENROUTER_API_KEY",
    ]

out = (root / "deploy/50-litellm/config.yaml.tmpl").read_text().replace(
    "{{MODEL_LIST}}", "\n".join(routes))
(root / "deploy/50-litellm/config.rendered.yaml").write_text(out)
print(f"rendered {len(routes)} lines; remote route: "
      f"{'enabled' if openrouter_key else 'absent (no key)'}")
