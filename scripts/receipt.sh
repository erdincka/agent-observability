#!/usr/bin/env bash
# Chapter 9: the receipt. Everything a reviewer needs to establish, from the
# stored record alone, what one run did and whether the record is whole.
#
#   make receipt RUN=<run id>
#
# Every check is a query over the standard tables. Standard attribute names
# where they exist, local ones (triage.*, authz.*, agent_obs.*) where they do
# not — the guide flags which is which. Exits non-zero if any check fails.
set -euo pipefail
cd "$(dirname "$0")/.."
RUN="${1:?run id}"
q() { make -s ch-query Q="$1"; }
fail=0
check() { # label, condition-string, detail
  if [ "$2" = "ok" ]; then printf '  [ok]   %s\n' "$1"; else printf '  [FAIL] %s%s\n' "$1" "${3:+ — $3}"; fail=1; fi
}

TID=$(q "SELECT TraceId FROM otel_traces WHERE SpanAttributes['triage.run_id']='$RUN' LIMIT 1")
[ -n "$TID" ] || { echo "no trace for run $RUN"; exit 1; }

echo "== receipt for run $RUN"
q "SELECT concat('  trace      ', TraceId, '\n  incident   ', SpanAttributes['triage.incident_id'], '\n  route      ', SpanAttributes['triage.model_route'], '\n  principal  ', SpanAttributes['enduser.id'], '\n  role       ', SpanAttributes['agent_obs.role'], '\n  image      ', SpanAttributes['triage.image'], '\n  started    ', toString(Timestamp), '\n  duration   ', toString(round(Duration/1e9,1)), ' s') FROM otel_traces WHERE TraceId='$TID' AND SpanName='triage_run' FORMAT TSVRaw"

# 1. completeness: settle, then no dangling parents
prev=-1; for i in $(seq 1 20); do n=$(q "SELECT count() FROM otel_traces WHERE TraceId='$TID'"); [ "$n" = "$prev" ] && break; prev=$n; sleep 3; done
dangling=$(q "SELECT count() FROM otel_traces WHERE TraceId='$TID' AND ParentSpanId!='' AND ParentSpanId NOT IN (SELECT SpanId FROM otel_traces WHERE TraceId='$TID')")
services=$(q "SELECT arrayStringConcat(arraySort(groupUniqArray(ServiceName)), ', ') FROM otel_traces WHERE TraceId='$TID'")
echo "== 1. completeness   ($n spans; services: $services)"
check "no span points at a parent that was never exported" "$([ "$dangling" = 0 ] && echo ok || echo no)" "$dangling dangling"

# 2. reconciliation: agent-side sums equal gateway-side sums
read -r a_in a_out <<<"$(q "SELECT sum(toUInt64OrZero(SpanAttributes['gen_ai.usage.input_tokens'])), sum(toUInt64OrZero(SpanAttributes['gen_ai.usage.output_tokens'])) FROM otel_traces WHERE TraceId='$TID' AND SpanAttributes['gen_ai.operation.name']='invoke_agent' AND SpanAttributes['gen_ai.usage.input_tokens']!=''" | tr '\t' ' ')"
read -r g_in g_out <<<"$(q "SELECT sum(toUInt64OrZero(SpanAttributes['gen_ai.usage.input_tokens'])), sum(toUInt64OrZero(SpanAttributes['gen_ai.usage.output_tokens'])) FROM otel_traces WHERE TraceId='$TID' AND ServiceName='litellm-gateway' AND SpanName LIKE 'chat%'" | tr '\t' ' ')"
echo "== 2. reconciliation   (agents in=$a_in out=$a_out; gateway in=$g_in out=$g_out)"
check "agent-side token sums equal gateway-side sums" "$([ "$a_in" = "$g_in" ] && [ "$a_out" = "$g_out" ] && echo ok || echo no)"

# 3. who did what
echo "== 3. agents"
q "SELECT concat('  ', rpad(SpanAttributes['gen_ai.agent.name'], 10), rpad(SpanAttributes['triage.outcome'], 10), 'calls=', SpanAttributes['triage.model_calls'], ' in=', SpanAttributes['gen_ai.usage.input_tokens'], ' out=', SpanAttributes['gen_ai.usage.output_tokens'], ' reasoning=', SpanAttributes['gen_ai.usage.reasoning.output_tokens'], if(SpanAttributes['triage.denied_by']!='', concat(' denied_by=', SpanAttributes['triage.denied_by']), ''), if(SpanAttributes['triage.degraded_reason']!='', concat(' degraded=', SpanAttributes['triage.degraded_reason']), '')) FROM otel_traces WHERE TraceId='$TID' AND SpanAttributes['gen_ai.operation.name']='invoke_agent' AND SpanAttributes['gen_ai.usage.input_tokens']!='' ORDER BY Timestamp"
echo "== 4. model calls, as the gateway saw them"
q "SELECT concat('  ', rpad(SpanAttributes['litellm.metadata.user_api_key_alias'], 18), rpad(SpanAttributes['litellm.provider.model'], 36), 'calls=', toString(count()), ' end_user=', any(SpanAttributes['litellm.end_user.id'])) FROM otel_traces WHERE TraceId='$TID' AND ServiceName='litellm-gateway' AND SpanName LIKE 'chat%' GROUP BY SpanAttributes['litellm.metadata.user_api_key_alias'], SpanAttributes['litellm.provider.model'] ORDER BY 1"
refused=$(q "SELECT count() FROM otel_traces WHERE TraceId='$TID' AND ServiceName='litellm-gateway' AND SpanKind='Server' AND StatusCode='Error'")
guard=$(q "SELECT countIf(SpanAttributes['litellm.guardrail.status']='guardrail_intervened') FROM otel_traces WHERE TraceId='$TID'")
echo "  gateway refusals=$refused  guardrail interventions=$guard"
echo "== 5. tool calls, as the servers saw them"
q "SELECT concat('  ', rpad(ServiceName, 13), rpad(SpanAttributes['authz.tool'], 22), rpad(SpanAttributes['authz.decision'], 6), rpad(SpanAttributes['gen_ai.agent.name'], 10), rpad(SpanAttributes['authz.role'], 9), SpanAttributes['agent_obs.access.resource'], ' args#', SpanAttributes['agent_obs.access.args_sha256']) FROM otel_traces WHERE TraceId='$TID' AND SpanAttributes['authz.decision']!='' ORDER BY Timestamp"

# 6. content
leaks=$(q "SELECT count() FROM otel_traces ARRAY JOIN mapValues(SpanAttributes) AS v WHERE TraceId='$TID' AND (v LIKE '%You are the retriever%' OR v LIKE '%You are the analyser%' OR v LIKE '%Incident to investigate%' OR v LIKE '%LIKELY CAUSE%')")
logleaks=$(q "SELECT count() FROM otel_logs ARRAY JOIN mapValues(LogAttributes) AS v WHERE TraceId='$TID' AND (v LIKE '%You are the%' OR v LIKE '%Incident to investigate%')")
masked=$(q "SELECT count() FROM otel_traces WHERE TraceId='$TID' AND SpanAttributes['redaction.masked.keys']!=''")
echo "== 6. content   (spans with redaction applied: $masked)"
check "no prompt, completion or incident text in any stored span attribute" "$([ "$leaks" = 0 ] && echo ok || echo no)" "$leaks values"
check "none in any stored log record" "$([ "$logleaks" = 0 ] && echo ok || echo no)" "$logleaks values"

# 7. routing and retention
restricted=$(q "SELECT count() FROM otel_restricted.otel_traces WHERE TraceId='$TID'" 2>/dev/null || echo 0)
flagged=$(q "SELECT count() FROM otel_traces WHERE TraceId='$TID' AND (SpanAttributes['triage.outcome'] IN ('denied','truncated','empty','degraded') OR SpanAttributes['authz.decision']='deny' OR SpanAttributes['litellm.guardrail.status']='guardrail_intervened' OR StatusCode='Error')")
echo "== 7. routing   (flagged spans: $flagged; copies in the restricted store: $restricted)"
if [ "$flagged" != 0 ]; then check "a flagged trace is present, whole, in the restricted store" "$([ "$restricted" = "$n" ] && echo ok || echo no)" "$restricted of $n — run: make restricted-promote"; else check "an unflagged trace is not in the restricted store" "$([ "$restricted" = 0 ] && echo ok || echo no)"; fi
disk=$(q "SELECT arrayStringConcat(groupUniqArray(disk_name), ',') FROM system.parts WHERE database='otel' AND table='otel_traces' AND active AND partition = (SELECT toString(toDate(min(Timestamp))) FROM otel.otel_traces WHERE TraceId='$TID')")
echo "  partition storage: $disk   (moves to s3_cold after a day; deleted after 7 years)"

# 8. digest: a fingerprint of the stored record, for comparison later
digest=$(q "SELECT hex(SHA256(arrayStringConcat(arraySort(groupArray(concat(SpanId, '|', ParentSpanId, '|', SpanName, '|', ServiceName, '|', toString(Duration), '|', toString(SpanAttributes)))), '\n'))) FROM otel_traces WHERE TraceId='$TID'")
echo "== 8. digest   sha256 over every span's id, parent, name, service, duration and attributes, sorted"
echo "  $digest"
if [ -f "receipts/$RUN.digest" ]; then
  check "digest matches the receipt recorded earlier ($(cat "receipts/$RUN.digest" | cut -c1-16)…)" "$([ "$(cat "receipts/$RUN.digest")" = "$digest" ] && echo ok || echo no)" "the stored record has changed"
else
  mkdir -p receipts && echo "$digest" > "receipts/$RUN.digest" && echo "  recorded in receipts/$RUN.digest (gitignored; a real deployment writes this to the archive bucket)"
fi

echo "== result: $([ $fail = 0 ] && echo 'every check passed' || echo 'CHECKS FAILED')"
exit $fail
