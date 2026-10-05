#!/usr/bin/env python3
"""The evaluation loop (guide chapter 11): was the agent right?

    make evaluate N=1 ROUTE=local

Runs every incident in the corpus N times through `make workflow-triage`,
scores each run, and records it in MLflow: one experiment ("triage"), one
MLflow run per triage run, with the scores as metrics and the run's identity
(run id, trace id, incident, route, image, principal) as params, so runs can
be compared across routes and images in the MLflow UI.

Two sources per run, deliberately kept apart:

  - the *trace*, from ClickHouse: outcome per agent, tokens, tool decisions,
    evidence and domain counts. What the agent did.
  - the *output*, from the Job's log: the hypothesis and the report. Content,
    which the trace does not hold, read from the process that produced it and
    not stored anywhere but MLflow's own record of this evaluation. Whether
    the output was right.

Scoring is rule-based and small, because judgement quality is not what the
lab demonstrates. What it demonstrates is that the two questions have
different evidence and both can be answered per run:

  acknowledged_insufficient_evidence   for `no-evidence`: did the analyser say so
                                       instead of inventing a cause (the one
                                       incident with a knowable right answer)
  retrieved_expected_runbook           did the retriever fetch or find the runbook
                                       written for this incident
  hypothesis_cites_evidence            does the hypothesis cite numbered items
  confident_cause_without_evidence     a stated cause on a run with no evidence

MLflow is reached through the lab gateway (GATEWAY_IP in .env) with a Host
header; set MLFLOW_URL and MLFLOW_HOST to reach it another way.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

MLFLOW_URL = os.getenv("MLFLOW_URL") or f"http://{os.getenv('GATEWAY_IP', '127.0.0.1')}"
MLFLOW_HOST = os.getenv("MLFLOW_HOST", "mlflow.kube.local")
EXPERIMENT = "triage"

EXPECTED_RUNBOOK = {
    "checkout-latency": "latency-regression",
    "restart-loop": "pod-restart-loop",
    "disk-pressure": "storage-pressure",
    "no-evidence": None,
    "leaked-secret": None,
}
INSUFFICIENT = re.compile(
    r"insufficient|not enough evidence|no (direct |specific )?evidence|cannot (be )?determine|"
    r"does not support|unable to (determine|identify)|no clear cause|lack of evidence", re.I)
CONFIDENT = re.compile(r"most likely cause is|the cause is|caused by|root cause is", re.I)


def sh(cmd: list[str]) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def ch(q: str) -> str:
    return sh(["make", "-s", "ch-query", f"Q={q}"]).strip()


def mlflow(path: str, body: dict | None = None, method: str = "POST"):
    req = urllib.request.Request(
        f"{MLFLOW_URL}/api/2.0/mlflow/{path}", method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json", "Host": MLFLOW_HOST},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or b"{}")


def experiment_id() -> str:
    try:
        return mlflow(f"experiments/get-by-name?experiment_name={EXPERIMENT}", method="GET")["experiment"]["experiment_id"]
    except urllib.error.HTTPError:
        return mlflow("experiments/create", {"name": EXPERIMENT})["experiment_id"]


def triage(incident: str, route: str) -> str:
    """Run one triage Job and return its log."""
    return sh(["make", "-s", "workflow-triage", f"INCIDENT={incident}", f"ROUTE={route}"])


def parse_log(log: str) -> dict:
    run = re.search(r"^=== run (\w+) \| incident (\S+) \| route (\S+) ===", log, re.M)
    hyp = re.search(r"=== hypothesis ===\n(.*?)\n=== report ===", log, re.S)
    rep = re.search(r"=== report ===\n(.*)\Z", log, re.S)
    return {
        "run_id": run.group(1) if run else "", "incident": run.group(2) if run else "",
        "route": run.group(3) if run else "",
        "hypothesis": (hyp.group(1) if hyp else "").strip(),
        "report": (rep.group(1) if rep else "").strip(),
        "evidence_lines": re.findall(r"^\[\d+\] (\S+)\(", log, re.M),
    }


def trace_facts(run_id: str) -> dict:
    tid = ""
    for _ in range(20):
        tid = ch(f"SELECT TraceId FROM otel_traces WHERE SpanAttributes['triage.run_id']='{run_id}' LIMIT 1")
        if tid:
            break
        time.sleep(3)
    prev = -1
    for _ in range(20):
        n = int(ch(f"SELECT count() FROM otel_traces WHERE TraceId='{tid}'") or 0)
        if n == prev:
            break
        prev = n
        time.sleep(3)
    rows = ch(f"SELECT SpanAttributes['gen_ai.agent.name'], SpanAttributes['triage.outcome'], SpanAttributes['gen_ai.usage.input_tokens'], SpanAttributes['gen_ai.usage.output_tokens'], SpanAttributes['gen_ai.usage.reasoning.output_tokens'], SpanAttributes['triage.model_calls'] FROM otel_traces WHERE TraceId='{tid}' AND SpanAttributes['gen_ai.operation.name']='invoke_agent' AND SpanAttributes['gen_ai.usage.input_tokens']!='' FORMAT TSV")
    agents = {}
    for line in rows.splitlines():
        a, outcome, i, o, r, calls = line.split("\t")
        agents[a] = {"outcome": outcome, "in": int(i or 0), "out": int(o or 0), "reasoning": int(r or 0), "calls": int(calls or 0)}
    run_span = ch(f"SELECT SpanAttributes['triage.evidence_items'], SpanAttributes['triage.domains_covered'], SpanAttributes['triage.image'], SpanAttributes['enduser.id'], toString(round(Duration/1e9,1)) FROM otel_traces WHERE TraceId='{tid}' AND SpanName='triage_run' FORMAT TSV").split("\t")
    denies = int(ch(f"SELECT count() FROM otel_traces WHERE TraceId='{tid}' AND SpanAttributes['authz.decision']='deny'") or 0)
    dangling = int(ch(f"SELECT count() FROM otel_traces WHERE TraceId='{tid}' AND ParentSpanId!='' AND ParentSpanId NOT IN (SELECT SpanId FROM otel_traces WHERE TraceId='{tid}')") or 0)
    return {"trace_id": tid, "spans": prev, "agents": agents, "evidence_items": int(run_span[0] or 0),
            "domains_covered": int(run_span[1] or 0), "image": run_span[2], "principal": run_span[3],
            "duration_s": float(run_span[4] or 0), "tool_denials": denies, "dangling": dangling}


def score(incident: str, out: dict, facts: dict) -> dict:
    expected = EXPECTED_RUNBOOK.get(incident)
    hyp = out["hypothesis"]
    retrieved = 0.0
    if expected:
        retrieved = 1.0 if any(expected in ln for ln in out["evidence_lines"]) or f'"{expected}"' in hyp else 0.0
    cites = 1.0 if re.search(r"\[\d+\]", hyp) else 0.0
    ack = 1.0 if INSUFFICIENT.search(hyp) else 0.0
    confident_without = 1.0 if (CONFIDENT.search(hyp) and facts["evidence_items"] == 0) else 0.0
    return {
        "acknowledged_insufficient_evidence": ack,
        "retrieved_expected_runbook": retrieved,
        "hypothesis_cites_evidence": cites,
        "confident_cause_without_evidence": confident_without,
        # the one pass/fail with a knowable right answer
        "correct": (ack if incident == "no-evidence" else retrieved) if expected is not None or incident == "no-evidence" else 0.0,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=1)
    ap.add_argument("--route", default="local")
    ap.add_argument("--incidents", default="checkout-latency,restart-loop,disk-pressure,no-evidence")
    args = ap.parse_args()
    exp = experiment_id()
    print(f"MLflow experiment {EXPERIMENT} ({exp}) at {MLFLOW_URL} [{MLFLOW_HOST}]")
    for i in range(args.n):
        for incident in args.incidents.split(","):
            t0 = int(time.time() * 1000)
            log = triage(incident, args.route)
            out = parse_log(log)
            facts = trace_facts(out["run_id"])
            s = score(incident, out, facts)
            r = mlflow("runs/create", {"experiment_id": exp, "start_time": t0, "run_name": f"{incident}/{out['run_id']}",
                                       "tags": [{"key": "incident", "value": incident}, {"key": "route", "value": args.route},
                                                {"key": "trace_id", "value": facts["trace_id"]}, {"key": "image", "value": facts["image"]}]})
            rid = r["run"]["info"]["run_id"]
            metrics = [{"key": k, "value": v, "timestamp": t0, "step": 0} for k, v in s.items()]
            metrics += [{"key": k, "value": float(facts[k]), "timestamp": t0, "step": 0}
                        for k in ("evidence_items", "domains_covered", "duration_s", "tool_denials", "dangling", "spans")]
            for a, f in facts["agents"].items():
                metrics += [{"key": f"{a}.input_tokens", "value": f["in"], "timestamp": t0, "step": 0},
                            {"key": f"{a}.output_tokens", "value": f["out"], "timestamp": t0, "step": 0},
                            {"key": f"{a}.reasoning_tokens", "value": f["reasoning"], "timestamp": t0, "step": 0},
                            {"key": f"{a}.model_calls", "value": f["calls"], "timestamp": t0, "step": 0},
                            {"key": f"{a}.ok", "value": 1.0 if f["outcome"] == "ok" else 0.0, "timestamp": t0, "step": 0}]
            params = [{"key": "run_id", "value": out["run_id"]}, {"key": "incident", "value": incident},
                      {"key": "route", "value": args.route}, {"key": "image", "value": facts["image"]},
                      {"key": "principal", "value": facts["principal"]}, {"key": "expected_runbook", "value": EXPECTED_RUNBOOK.get(incident) or "none"}]
            params += [{"key": f"{a}.outcome", "value": f["outcome"]} for a, f in facts["agents"].items()]
            mlflow("runs/log-batch", {"run_id": rid, "metrics": metrics, "params": params})
            # The output, as MLflow's record of this evaluation only. Never on a span.
            mlflow("runs/log-batch", {"run_id": rid, "tags": [{"key": "hypothesis", "value": out["hypothesis"][:5000]}]})
            mlflow("runs/update", {"run_id": rid, "status": "FINISHED", "end_time": int(time.time() * 1000)})
            print(f"  {incident:18} run {out['run_id']}  correct={s['correct']:.0f}  evidence={facts['evidence_items']} domains={facts['domains_covered']}  "
                  f"outcomes={ {a: f['outcome'] for a, f in facts['agents'].items()} }  -> mlflow {rid[:8]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
