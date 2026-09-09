#!/usr/bin/env bash
# Push one hand-built OTLP span into the Collector and prove it reaches ClickHouse.
#
# Deliberately has no application, no SDK and no instrumentation library in it.
# If this passes, the pipeline is sound and any later failure is the app's fault,
# not the plumbing's — which is worth an hour of debugging later on.
set -euo pipefail
cd "$(dirname "$0")/.."

PLATFORM_NS=agent-obs-platform
set -a; . ./.env; set +a

TRACE_ID=$(python3 -c "import secrets; print(secrets.token_hex(16))")
SPAN_ID=$(python3 -c "import secrets; print(secrets.token_hex(8))")
SERVICE="smoke-test"

echo "==> trace_id=${TRACE_ID}"

PAYLOAD=$(python3 - "$TRACE_ID" "$SPAN_ID" "$SERVICE" <<'PY'
import json, sys, time
trace_id, span_id, service = sys.argv[1], sys.argv[2], sys.argv[3]
now = time.time_ns()
print(json.dumps({"resourceSpans": [{
    "resource": {"attributes": [
        {"key": "service.name", "value": {"stringValue": service}},
    ]},
    "scopeSpans": [{
        "scope": {"name": "smoke-trace.sh"},
        "spans": [{
            "traceId": trace_id,
            "spanId": span_id,
            "name": "pipeline-smoke-test",
            "kind": 1,
            "startTimeUnixNano": str(now - 1_000_000),
            "endTimeUnixNano": str(now),
            "attributes": [
                {"key": "smoke.origin", "value": {"stringValue": "scripts/smoke-trace.sh"}},
            ],
            "status": {"code": 1},
        }],
    }],
}]}))
PY
)

echo "==> POST /v1/traces via an in-cluster pod"
echo "$PAYLOAD" | kubectl run "smoke-otlp-$$" \
    --namespace "$PLATFORM_NS" --rm -i --quiet --restart=Never \
    --image=curlimages/curl:8.11.1 -- \
    curl -sS -o /dev/null -w 'HTTP %{http_code}\n' \
        -X POST 'http://otel-collector.agent-obs-platform.svc.cluster.local:4318/v1/traces' \
        -H 'Content-Type: application/json' --data-binary @-

echo "==> polling ClickHouse (batch processor flushes every 5s)"
for i in $(seq 1 24); do
    COUNT=$(kubectl exec -n "$PLATFORM_NS" clickhouse-0 -- \
        clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
        --database "$CLICKHOUSE_DB" \
        --query "SELECT count() FROM otel_traces WHERE TraceId = '${TRACE_ID}'" 2>/dev/null || echo 0)
    if [ "${COUNT:-0}" -gt 0 ]; then
        echo "==> PASS: span found in ClickHouse after ${i} attempt(s)"
        kubectl exec -n "$PLATFORM_NS" clickhouse-0 -- \
            clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
            --database "$CLICKHOUSE_DB" --format Vertical \
            --query "SELECT Timestamp, TraceId, SpanId, SpanName, ServiceName, SpanAttributes
                     FROM otel_traces WHERE TraceId = '${TRACE_ID}'"
        exit 0
    fi
    sleep 5
done

echo "==> FAIL: span never reached ClickHouse. Check: make collector-logs" >&2
exit 1
