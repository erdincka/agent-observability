# Runbook: storage pressure

## Symptoms
Writes fail, pods are evicted, or a database reports it cannot allocate space. On
node-local storage the failure is usually abrupt rather than gradual.

## First checks
1. Node disk usage. Evictions from `ephemeral-storage` pressure name the node in the
   event, not the volume.
2. `kubectl get pvc -A` — check bound capacity against what the workload actually needs.
3. Whether the StorageClass supports expansion. If `ALLOWVOLUMEEXPANSION` is false, the
   volume cannot be grown and the fix is a migration, not a resize.

## Common causes
- Retention not configured. Telemetry and log stores grow without bound unless a TTL was
  set at table creation; adding one later does not reclaim what has already accumulated.
- A volume sized for an initial estimate that was never revisited.
- Node-local provisioners pinning a volume to one node, so the cluster has capacity while
  the workload does not.

## Escalation
On a single-replica datastore with node-local storage, treat disk pressure on that node as
a data-availability risk, not just a capacity one.
