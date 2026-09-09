# Runbook: service latency regression

## Symptoms
p99 latency for a service rises sharply while error rate stays flat. Throughput is
usually unchanged or slightly down.

## First checks
1. `rate(http_request_duration_seconds_bucket[5m])` — confirm the regression is real and
   not a single slow client skewing an average.
2. Compare against the same window yesterday. Weekly and daily cycles are the most common
   cause of a "regression" that is not one.
3. Check whether the increase is uniform across pods. A single slow replica points at a
   node or a volume, not at code.

## Common causes
- A deploy in the preceding hour. Correlate with recent commits before anything else.
- A dependency slowing down: the service is the victim, not the cause. Check downstream
  latency before investigating this service's code.
- Connection pool exhaustion. Latency rises while CPU stays low — the tell is waiting,
  not working.
- Node-level CPU pressure or a noisy neighbour on the same node.

## Escalation
If latency is rising and error rate has begun to follow, treat it as an availability
incident rather than a performance one.
