# 11. Evaluation: was it right

**Question it answers:** observability says what the agent did; evaluation says whether
it was right. An audit committee asks both, and the evidence for each is different.
**Status:** built 2026-09-13, deliberately small. MLflow on the platform side, one
experiment, one MLflow run per triage run, rule-based scores.
**Tools:** MLflow 3 (chart community-charts/mlflow), CloudNativePG, MinIO, ClickHouse.

## Run

```bash
make mlflow                     # MLflow, its database, the route
make evaluate N=1 ROUTE=local   # every incident in the corpus, N times, scored
make evaluate N=1 ROUTE=remote  # the same, on the other route, to compare
```

Then `http://mlflow.kube.local`, experiment *triage*.

## What you should see

One MLflow run per triage run, named `<incident>/<run id>`, tagged with the trace id, the
route and the image, with:

| metric | meaning |
| :- | :- |
| `correct` | the one pass/fail with a knowable answer: for `no-evidence`, did the analyser say the evidence was insufficient; for the runbook-backed incidents, did the retriever fetch or find the runbook written for it |
| `acknowledged_insufficient_evidence` | the analyser said so, whatever the incident |
| `retrieved_expected_runbook` | the matching runbook appears in the evidence |
| `hypothesis_cites_evidence` | the hypothesis cites numbered items |
| `confident_cause_without_evidence` | a stated cause on a run with zero evidence, the failure shape the corpus was built to catch |
| `<agent>.input_tokens`, `.output_tokens`, `.reasoning_tokens`, `.model_calls`, `.ok` | per agent, from the trace |
| `evidence_items`, `domains_covered`, `duration_s`, `tool_denials`, `dangling`, `spans` | per run, from the trace |

and the hypothesis text as a tag, so a reviewer can read what was scored.

The first pass, `local` route, one run per incident:

| run | correct | evidence items | domains |
| :- | -: | -: | -: |
| checkout-latency | 0 | 3 | 2 |
| restart-loop | 0 | 3 | 2 |
| disk-pressure | 0 | 5 | 3 |
| no-evidence | 0 | 4 | 2 |

Zero of four. The 3B model lists the runbooks and does not fetch the one written for the
incident, and on `no-evidence` it names a cause. That is the measurement, not a defect
in the loop; the same pass on the `remote` route is the comparison the chapter exists
for. It also exposed a gap in the scorer: irrelevant tool output counts as evidence
items, so `confident_cause_without_evidence` stayed at zero on a run with four
irrelevant items. Relevance is a judgement the rules do not make.

## What it means

**Two sources per run, kept apart on purpose.** What the agent *did* comes from the trace
in ClickHouse, the same rows the receipt reads. Whether it was *right* needs the output,
which the trace does not hold, by design. The evaluation reads it from the Job's log,
the process that produced it, and stores it in MLflow's record of this evaluation and
nowhere else. Content stays out of the telemetry store even here.

**The corpus has one incident with a knowable right answer.** `no-evidence` describes a
service that does not exist; every tool returns nothing relevant; the correct output is
"insufficient evidence". A pipeline that produces a confident cause for it is doing
autocomplete, and `confident_cause_without_evidence` is the metric that catches it.
The other incidents are scored on retrieval, which is checkable, not on diagnosis,
which is not.

**Comparison is the point, not the score.** The same corpus on `local` and `remote`, or
on two images, side by side in the MLflow UI, is what an audit committee can act on. A
single run is an anecdote (chapter 5).

## Where it breaks

- The scoring is regular expressions over one paragraph. Judgement quality is not what
  the lab demonstrates; the shape of the loop is.
- MLflow 3 rejects Host headers it was not told about, and this chart version takes the
  backend store's credentials as literal values, so `make mlflow` reads them from the
  CNPG Secret and passes them to Helm; they reach the release and never the repository.
- The evaluation drives `make workflow-triage`, so it runs one incident at a time and a
  pass over the corpus takes minutes. That is the same Job-name constraint as the demos.

## In an enterprise

"Was it right" is the question the observability stack cannot answer and the one the
committee asks first. The lesson of this chapter is where the two records meet: the same
run id, the same trace id, in both systems, so that a score in MLflow can be traced to a
receipt in ClickHouse and back.

## Read more

- `scripts/evaluate.py`, `deploy/95-mlflow/`.
- LEARNINGS.md, 2026-09-13: *Chapter 11*.
