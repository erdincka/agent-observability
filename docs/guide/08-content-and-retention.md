# 8. Content, redaction and retention

**Question it answers:** what does the trace record about the *data* an agent touched,
without recording the content? Where is that enforced, and where does the record go when
it must outlive the hot store?
**Status:** built 2026-09-13. Redaction on the only write path, a restricted store fed by
per-trace routing, an S3 archive, a cold tier, and a non-content record of data access.
**Tools:** OTel Collector `redaction`, `tail_sampling`, `awss3` and a second `clickhouse`
exporter; ClickHouse S3 disk, storage policy and TTL; MinIO.

## Run

```bash
make collector                 # redaction, restricted routing, archive
make clickhouse && make ch-restricted-user && make retention
make demo-content-redacted     # SDK content capture ON for one run; prove nothing lands
make demo-restricted-access    # the restricted reader: allowed there, refused here
make retention-status          # partitions by disk; objects in MinIO
make retention-move-oldest     # move a partition to S3 by hand (the TTL does it nightly)
```

## Look

`make demo-content-redacted` runs `scripts/content-check.sh` for you. By hand:

```bash
# any stored value carrying prompt or incident text? (spans and log records)
make ch-query Q="SELECT count() FROM otel_traces ARRAY JOIN mapValues(SpanAttributes) AS v WHERE TraceId='<id>' AND (v LIKE '%You are the retriever%' OR v LIKE '%Incident to investigate%')"

# what redaction stripped, per service
make ch-query Q="SELECT ServiceName, SpanAttributes['redaction.masked.keys'], count() FROM otel_traces WHERE TraceId='<id>' AND SpanAttributes['redaction.masked.keys']!='' GROUP BY 1,2"

# what a tool touched, without its arguments
make ch-query Q="SELECT ServiceName, SpanAttributes['authz.tool'] AS tool, SpanAttributes['agent_obs.access.resource'] AS resource, SpanAttributes['agent_obs.access.args_sha256'] AS args FROM otel_traces WHERE TraceId='<id>' AND SpanAttributes['agent_obs.access.resource']!=''"
```

## What you should see

With the SDK deliberately emitting content, on run `4b6e29c54965`:

```
spans: 180
span attribute values containing prompt/incident text: 0
log attribute values containing prompt/incident text:  0
```

and, per service, what the Collector masked before storage:

| service | masked keys | spans |
| :- | :- | -: |
| litellm-gateway | `litellm.guardrail.response` | 8 |
| triage-workflow | `gen_ai.input.messages`, `gen_ai.output.messages`, `gen_ai.system_instructions`, `gen_ai.tool.call.arguments` | 6 |
| triage-workflow | `mcp.request.payload`, `mcp.response.payload` | 42 |
| triage-workflow | `db.query.text` | 16 |

The same run, flagged because the model asked to restart a deployment and was denied,
appears whole in `otel_restricted.otel_traces` (180 spans, one trace). The restricted
reader counts them and is refused on the main table with `ACCESS_DENIED`. Partitions older
than a day sit on the `s3_cold` disk; the archive bucket holds gzip'd OTLP JSON batches.

## What it means

**The claim is now the honest version.** Not "we never emit content" but "even when a
component does, it cannot land". The demo turns capture on at the SDK, the loudest
possible failure of posture, and the store stays clean. The spans say what was stripped,
so a reviewer can tell "no content because none was sent" from "no content because it was
removed".

**The list of keys was measured, not guessed, and one of them was a surprise.** With
capture on, the SDK put content in five attribute families and in log records. The
sixth family came from the gateway: `litellm.guardrail.response`. LiteLLM's guardrail
success record carries the request it approved, messages included, onto the guardrail's
span, on a gateway configured for `no_content`. Since chapter 7 switched the guardrail on,
every run's prompts had been landing in ClickHouse through that one attribute. Nineteen
spans held prompt text when it was found. The Collector rule fixed it in one line; the
rows already stored were masked in place. CONTRIBUTIONS item 13.

**Data access has a non-content record.** Tool arguments are content and stay withheld.
Each tool now records a resource identifier the operator chose (`prometheus:query`,
`runbook:latency-regression`, `k8s:deployments/agent-obs-app/mcp-runbooks`) and a short
hash of its canonical arguments. The resource carries meaning; the hash carries identity,
so "did two runs ask the same thing" is answerable and the query itself is not. Recorded
before the authorization decision, so a denied call still says what it was denied access
*to*.

**Routing is per trace, which the Collector can do and the UI cannot.** The tail sampler
holds each trace for 45 seconds and copies it whole to the restricted database if any span
carries a refusal, a non-`ok` outcome, a guardrail intervention or an error. The main store
keeps everything; the restricted store is the audit queue. The two databases share an
instance and differ in exactly one thing, who may read them.

**Retention is three things, not one.** The hot table moves parts to S3 after a day and
deletes after seven years, under ClickHouse's own TTL. The archive is a second, independent
copy: every batch, after redaction, as OTLP JSON in a versioned bucket. And the cold tier
is still queryable. A reviewer in year six queries the same table.

## Where it breaks

- **The guardrail leak.** See above. Any gateway feature that logs "what it saw" is a
  content path, and `no_content` does not cover it.
- **Redaction masks; it does not delete.** A masked attribute is still a key, and
  `redaction.masked.keys` says which. The content is gone; its existence is not. That is
  deliberate: the record should show a component tried to emit content.
- **The archive is only as immutable as the bucket.** Versioning stops silent overwrite;
  object lock would stop deletion, and is not on. Chapter 9's receipt records a digest.
- **The hash of a small argument space is reversible** (a runbook name, a deployment
  name). The resource identifier is what carries meaning for those; the hash is for
  free-text queries.
- ClickHouse required the tiered policy to keep the old volume's name, `default`. The
  error names the rule; the rule is not in the documentation an operator reads first.
- The `awss3` exporter logs nothing on success and, in this configuration, nothing on
  failure either; its counters (`otelcol_exporter_sent_spans`) are the only signal.

## In an enterprise

The spec leaves the content decision to the organisation. This chapter's position is that
the decision matters less than where it is enforced: an SDK flag is a request, a gateway
setting is a request, and a processor on the only write path is a control. The guardrail
finding is the proof, because both requests were honoured and content still leaked, and
only the control caught it.

## Read more

- `deploy/20-otel-collector/values.yaml`, the whole pipeline with the reasoning inline.
- `deploy/10-clickhouse/clickhouse.yaml`, the S3 disk; `scripts/content-check.sh`.
- LEARNINGS.md, 2026-09-13: *Chapter 8*.
