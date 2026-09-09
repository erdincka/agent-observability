# Runbook: pod restart loop

## Symptoms
A pod cycles through `CrashLoopBackOff`, or restart count climbs steadily while the pod
appears `Running` between restarts.

## First checks
1. `kubectl logs <pod> --previous` — the logs of the *crashed* container, not the current
   one. This is the single most commonly missed step.
2. `kubectl describe pod <pod>` — look at the last state's exit code and reason.
3. Check whether the restart is OOMKill. Exit code 137 with reason `OOMKilled` means the
   memory limit, not the application.

## Common causes
- Memory limit set below actual working set. Common after a dependency upgrade.
- Failing readiness or liveness probe with too short an initial delay — the container is
  healthy but slow to start, and the probe kills it before it finishes.
- A missing or misspelled Secret or ConfigMap key: the container exits immediately on
  startup, usually with a clear message in the previous logs.
- Image architecture mismatch. On a mixed-architecture estate an `exec format error`
  means the image was built for the wrong platform.

## Escalation
If restarts began without a deployment change, suspect the node or the underlying volume
before the workload.
