#!/usr/bin/env bash
# Prove three things about the LiteLLM gateway at once:
#   1. a model call succeeds through the self-hosted route
#   2. the gateway's spans join an INCOMING traceparent rather than starting a
#      parallel trace — the property the whole topology depends on
#   3. no prompt or response content reaches storage
set -euo pipefail
cd "$(dirname "$0")/.."

PLATFORM_NS=agent-obs-platform
set -a; . ./.env; set +a
ROUTE="${1:-local}"

TRACE_ID=$(python3 -c "import secrets; print(secrets.token_hex(16))")
SPAN_ID=$(python3 -c "import secrets; print(secrets.token_hex(8))")

echo "==> caller trace_id=${TRACE_ID}  route=${ROUTE}"
echo "==> calling gateway with traceparent (CPU inference — allow a minute)"

kubectl run "gw-probe-$$" --namespace "$PLATFORM_NS" --rm -i --quiet --restart=Never \
    --image=curlimages/curl:8.11.1 -- \
    curl -sS --max-time 300 \
        -X POST 'http://litellm.agent-obs-platform.svc.cluster.local:4000/v1/chat/completions' \
        -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
        -H 'Content-Type: application/json' \
        -H "traceparent: 00-${TRACE_ID}-${SPAN_ID}-01" \
        -d "{\"model\":\"${ROUTE}\",\"max_tokens\":24,
             \"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: pong\"}]}" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print('==> model said:', repr(d['choices'][0]['message']['content'][:80]))"

echo "==> polling ClickHouse until the span count STOPS changing"
# Waiting for the first span is a race: the gateway emits several spans per
# request and the batch processor flushes them across more than one batch.
# Polling until two consecutive reads agree is the difference between seeing a
# one-span trace and the real three-span one.
PREV=-1; COUNT=0
for i in $(seq 1 30); do
    COUNT=$(kubectl exec -n "$PLATFORM_NS" clickhouse-0 -- \
        clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
        --database "$CLICKHOUSE_DB" \
        --query "SELECT count() FROM otel_traces WHERE TraceId='${TRACE_ID}'" 2>/dev/null || echo 0)
    if [ "${COUNT:-0}" -gt 0 ] && [ "${COUNT}" = "${PREV}" ]; then break; fi
    PREV=$COUNT
    sleep 5
done

if [ "${COUNT:-0}" -eq 0 ]; then
    echo "==> FAIL: gateway spans did not join the caller's trace" >&2
    exit 1
fi

echo "==> PASS: ${COUNT} span(s) on the caller's trace"
echo
echo "--- span tree ---"
kubectl exec -n "$PLATFORM_NS" clickhouse-0 -- \
    clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
    --database "$CLICKHOUSE_DB" \
    --query "SELECT SpanId, ParentSpanId, SpanKind, SpanName, ServiceName,
                    round(Duration/1e9, 2) AS sec
             FROM otel_traces WHERE TraceId='${TRACE_ID}' ORDER BY Timestamp FORMAT PrettyCompact"

echo
echo "--- gen_ai.* attributes captured ---"
kubectl exec -n "$PLATFORM_NS" clickhouse-0 -- \
    clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
    --database "$CLICKHOUSE_DB" \
    --query "SELECT DISTINCT k, v FROM otel_traces
             ARRAY JOIN mapKeys(SpanAttributes) AS k, mapValues(SpanAttributes) AS v
             WHERE TraceId='${TRACE_ID}' AND k LIKE 'gen_ai%' ORDER BY k FORMAT PrettyCompact"

echo
echo "--- CONTENT LEAK CHECK: any attribute holding the prompt or completion? ---"
LEAK=$(kubectl exec -n "$PLATFORM_NS" clickhouse-0 -- \
    clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
    --database "$CLICKHOUSE_DB" \
    --query "SELECT count() FROM otel_traces
             ARRAY JOIN mapValues(SpanAttributes) AS v
             WHERE TraceId='${TRACE_ID}' AND (v ILIKE '%pong%' OR v ILIKE '%single word%')")
if [ "${LEAK:-0}" -eq 0 ]; then
    echo "CLEAN: prompt and completion text appear in no span attribute."
else
    echo "LEAK: ${LEAK} attribute value(s) contain message content!" >&2
fi
