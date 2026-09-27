#!/usr/bin/env bash
# Copy flagged traces, whole, into the restricted store.
#
# Why this is no longer a Collector pipeline. Tail sampling decides a trace's
# fate at a fixed offset from its FIRST span — `decision_wait`, 45s here — and
# an agent run is minutes long with its flag-worthy event typically late: a
# denial mid-retrieval, a degraded outcome recorded only when the node finishes.
# Run 29c02aa387fb missed the window by 0.8 seconds and was never copied, so a
# receipt that demanded the flagged trace be present failed on a working lab.
# No decision window is reliably longer than an agent, so the decision has to be
# made after a trace is complete rather than a fixed time after it starts.
# See LEARNINGS.md, 2026-09-27.
#
# Two consequences worth stating plainly:
#   - The copy is taken from what is already stored, so it is identical to the
#     main record by construction. The old pipeline ran its own second redaction
#     pass, which could in principle diverge from the first.
#   - The Collector is no longer the only writer to ClickHouse. Nothing reaches
#     storage without passing redaction first, which is the property that
#     matters, but README.md now says this explicitly rather than implying that
#     one component writes everything.
#
# Idempotent: a trace is copied once, and only after it has been quiet for
# SETTLE, so "whole" is guaranteed rather than hoped for.
#
#   make restricted-promote                  # last 7 days, 60s settle
#   LOOKBACK='1 DAY' make restricted-promote
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

LOOKBACK="${LOOKBACK:-7 DAY}"
SETTLE="${SETTLE:-60 SECOND}"
NS=agent-obs-platform

q() { kubectl exec -i -n "$NS" clickhouse-0 -- clickhouse-client \
        --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" "$@"; }

# Created here rather than by the Collector's exporter, which no longer writes
# this database. `AS otel.otel_traces` copies the exporter's own schema, so the
# two stores stay structurally identical and `SELECT *` between them is safe.
q --query "CREATE DATABASE IF NOT EXISTS otel_restricted" >/dev/null
q --query "CREATE TABLE IF NOT EXISTS otel_restricted.otel_traces AS otel.otel_traces" >/dev/null

# The same four conditions the receipt checks, and the same ones the Collector's
# tail-sampling policies used. Kept in one place on purpose: if this list and
# the receipt's disagree, the receipt fails on traces that were never eligible.
FLAG="SpanAttributes['triage.outcome'] IN ('denied','truncated','empty','degraded')
   OR SpanAttributes['authz.decision'] = 'deny'
   OR SpanAttributes['litellm.guardrail.status'] = 'guardrail_intervened'
   OR StatusCode = 'Error'"

before=$(q --query "SELECT count() FROM otel_restricted.otel_traces")

pending=$(q --query "
  SELECT count() FROM (
    SELECT TraceId FROM otel.otel_traces
    WHERE Timestamp > now() - INTERVAL $LOOKBACK
    GROUP BY TraceId
    HAVING countIf($FLAG) > 0 AND max(Timestamp) < now() - INTERVAL $SETTLE
  ) WHERE TraceId NOT IN (SELECT DISTINCT TraceId FROM otel_restricted.otel_traces)")

q --query "
  INSERT INTO otel_restricted.otel_traces
  SELECT * FROM otel.otel_traces
  WHERE TraceId IN (
    SELECT TraceId FROM otel.otel_traces
    WHERE Timestamp > now() - INTERVAL $LOOKBACK
    GROUP BY TraceId
    HAVING countIf($FLAG) > 0 AND max(Timestamp) < now() - INTERVAL $SETTLE
  )
  AND TraceId NOT IN (SELECT DISTINCT TraceId FROM otel_restricted.otel_traces)"

after=$(q --query "SELECT count() FROM otel_restricted.otel_traces")
traces=$(q --query "SELECT uniqExact(TraceId) FROM otel_restricted.otel_traces")

echo "==> promoted $pending trace(s); spans $before -> $after"
echo "    restricted store now holds $traces trace(s), whole"
echo "    (lookback $LOOKBACK, settle $SETTLE; traces still in flight are left for the next run)"
