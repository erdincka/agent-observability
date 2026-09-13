#!/usr/bin/env python3
"""Mint the per-agent virtual keys at the gateway. Idempotent.

Runs *inside* the LiteLLM pod (piped over `kubectl exec -i`), so it needs no
route from the workstation to the gateway and reads the master key from the
pod's own environment rather than from argv. Prints one JSON object
{alias: key} on stdout, which `make litellm-keys` turns into the `agent-keys`
Secret in the app namespace.

Keys are deterministic: sk-agent-<alias>-<hmac(master_key, alias)>. Re-running
recreates the same values, so a Secret rendered on one day matches keys minted
on another, and a rotated master key rotates every agent key with it.

What each key encodes is the policy the gateway will enforce:

    retriever   models local+remote, 60 rpm      the agent that calls tools
    analyser    models local+remote, 30 rpm
    reporter    models local+remote, 30 rpm
    restricted  models remote only               demo: model access denied on the local route
    throttled   models local+remote, 2 rpm       demo: rate limit hit mid-run

All belong to team `triage`. The gateway stamps team, key alias and the
request's end-user id onto every span (LITELLM_OTEL_BAGGAGE_PROMOTED_KEYS), so
"which agent, on whose behalf" is on the gateway's spans without the caller
being trusted to say so.
"""

import hashlib
import hmac
import json
import os
import sys
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:4000"
MASTER = os.environ["LITELLM_MASTER_KEY"]
TEAM = "triage"

KEYS = {
    "retriever":  {"models": ["local", "remote"], "rpm_limit": 60},
    "analyser":   {"models": ["local", "remote"], "rpm_limit": 30},
    "reporter":   {"models": ["local", "remote"], "rpm_limit": 30},
    "restricted": {"models": ["remote"],          "rpm_limit": 60},
    "throttled":  {"models": ["local", "remote"], "rpm_limit": 2},
}


def api(method, path, body=None):
    req = urllib.request.Request(
        BASE + path, method=method,
        headers={"Authorization": f"Bearer {MASTER}", "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None,
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def key_value(alias):
    digest = hmac.new(MASTER.encode(), alias.encode(), hashlib.sha256).hexdigest()[:24]
    return f"sk-agent-{alias}-{digest}"


status, _ = api("GET", f"/team/info?team_id={TEAM}")
if status != 200:
    status, body = api("POST", "/team/new", {"team_id": TEAM, "team_alias": TEAM,
                                             "models": ["local", "remote"],
                                             "metadata": {"purpose": "incident triage agents"}})
    if status not in (200, 201):
        sys.exit(f"team/new failed: {status} {body}")
    print(f"created team {TEAM}", file=sys.stderr)

out = {}
for alias, policy in KEYS.items():
    key = key_value(alias)
    status, _ = api("GET", f"/key/info?key={key}")
    if status == 200:
        print(f"key agent-{alias}: exists", file=sys.stderr)
    else:
        status, body = api("POST", "/key/generate", {
            "key": key, "key_alias": f"agent-{alias}", "team_id": TEAM,
            "models": policy["models"], "rpm_limit": policy["rpm_limit"],
            "metadata": {"agent": alias, "managed_by": "scripts/litellm-keys.py"},
        })
        if status not in (200, 201):
            sys.exit(f"key/generate agent-{alias} failed: {status} {body}")
        print(f"key agent-{alias}: created ({policy})", file=sys.stderr)
    out[alias] = key

json.dump(out, sys.stdout)
