# 8. Content, redaction and retention

**Question it answers:** what does the trace record about the *data* an agent touched,
without recording the content? And where is that decision enforced?
**Status:** not built. Content capture is off at every layer, verified by probes. Nothing
redacts, routes, samples or archives yet.
**Tools:** OTel Collector processors (attributes, redaction, transform), routing and tail
sampling, ClickHouse TTL and S3 tiering, MinIO.

## The experiment, as planned

1. **Turn content capture on at the SDK, deliberately, and prove the Collector strips it
   before storage.** This is the honest version of the claim: not "we never emit it" but
   "even if a component does, it cannot land". The grep from chapter 2 is the assertion.
2. **Keep a non-content record of data access.** Tool arguments are withheld under
   `no_content`. The tool servers can emit instead a resource identifier, a hash of the
   arguments, or a classification, on an attribute this lab defines and flags as a local
   extension. The Collector can also hash a sensitive attribute in place.
3. **Route flagged traces to a restricted store.** Runs with a `deny` decision or a
   non-`ok` outcome go to a second ClickHouse database under separate access control;
   everything else to the main one.
4. **Tail sample.** Keep full traces for failed or flagged runs; sample the rest. Show
   that the run-level attributes from chapter 5 are what make the sampling decision
   expressible.
5. **Retain.** ClickHouse keeps traces for 720 hours today. Tier cold data to MinIO's
   `otel-archive` bucket, with versioning on, and show a trace being read back after its
   hot TTL. This is where the seven-year requirement lands, and where MinIO earns its
   place in the stack.

## What you should see, when built

The same run, twice: once with the SDK capturing content and the Collector stripping it,
once with the SDK not capturing. Identical rows in ClickHouse. And one attribute per tool
call that says what was accessed in a form that is not the query.

## Decisions to make before building

- **What "data access" is recorded as.** This is the design decision the semantic
  conventions leave to each organisation, and the one only a practitioner who has sat
  with a data protection officer can make well. It belongs to the author.
- **Hash or drop.** A hash allows "did two runs touch the same thing" without revealing
  what; a drop does not. A hash of low-entropy input is reversible.

## In an enterprise

The spec offers three modes for content, inline, external or none, and leaves the choice
to the organisation. The choice matters less than where it is enforced. An SDK flag is a
request. A Collector processor on the only write path is a control.

## Read more

- LEARNINGS.md: *MinIO, deliberately outside the cluster* (2026-09-09), for why the
  retention tier is a VM and not a PersistentVolume.
- CONTRIBUTIONS items 4 and 10, for the two places content posture nearly failed.
- [Governance matrix](../governance-matrix.md), rows "With what data access" and
  "Provable later".
