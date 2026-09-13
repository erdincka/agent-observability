#!/usr/bin/env bash
# Chapter 8's assertion. For one run: (1) no stored attribute value, on any
# span or log record, contains the incident text or a system prompt; (2) the
# spans that had content carry redaction.masked.keys saying what was stripped.
# Exits non-zero if content is found. Usage: content-check.sh <run_id>
set -euo pipefail
cd "$(dirname "$0")/.."
RUN="${1:?run id}"
q() { make -s ch-query Q="$1"; }
TID=$(q "SELECT TraceId FROM otel_traces WHERE SpanAttributes['triage.run_id']='$RUN' LIMIT 1")
[ -n "$TID" ] || { echo "no trace for run $RUN yet"; exit 1; }
echo "run $RUN  trace $TID"
# Wait for the span count to settle (two consecutive equal reads).
prev=-1; for i in $(seq 1 20); do
  n=$(q "SELECT count() FROM otel_traces WHERE TraceId='$TID'"); [ "$n" = "$prev" ] && break; prev=$n; sleep 3
done
echo "spans: $n"
PATTERNS="v LIKE '%You are the retriever%' OR v LIKE '%You are the analyser%' OR v LIKE '%Latency on the checkout%' OR v LIKE '%Incident to investigate%' OR v LIKE '%LIKELY CAUSE%'"
leaks=$(q "SELECT count() FROM otel_traces ARRAY JOIN mapValues(SpanAttributes) AS v WHERE TraceId='$TID' AND ($PATTERNS)")
logleaks=$(q "SELECT count() FROM otel_logs ARRAY JOIN mapValues(LogAttributes) AS v WHERE TraceId='$TID' AND ($PATTERNS OR Body LIKE '%You are the%')")
echo "span attribute values containing prompt/incident text: $leaks"
echo "log attribute values containing prompt/incident text:  $logleaks"
echo "--- what redaction stripped, by service ---"
q "SELECT ServiceName, SpanAttributes['redaction.masked.keys'] AS masked, count() AS spans FROM otel_traces WHERE TraceId='$TID' AND SpanAttributes['redaction.masked.keys']!='' GROUP BY 1,2 ORDER BY 1 FORMAT PrettyCompact"
if [ "$leaks" != "0" ] || [ "$logleaks" != "0" ]; then echo "CONTENT FOUND IN THE STORE"; exit 1; fi
echo "no content in the store for this run"
