#!/usr/bin/env bash
# Creates the buckets and the cluster's access credential on the MinIO VM.
#
# Runs `mc` over SSH on the VM itself rather than from the workstation, so the
# repository does not acquire an `mc` dependency and the root credential never
# leaves the host that already holds it.
#
# The cluster does NOT get the root credential. It gets a distinct MinIO user
# whose policy covers exactly these buckets and nothing else, so a leaked
# in-cluster Secret cannot read the backups of the thing that leaked it. Same
# reasoning as phase 2's virtual keys, one layer down.
#
# Safe to re-run: every step tolerates the object already existing.
set -euo pipefail
cd "$(dirname "$0")/../.."

set -a; . ./.env; set +a

MINIO_VM_IP="${MINIO_VM_IP:-10.1.1.20}"
MINIO_VM_USER="${MINIO_VM_USER:-${VM_USER:-ubuntu}}"
MINIO_BUCKETS="${MINIO_BUCKETS:-otel-archive clickhouse-cold cnpg-backups workflow-artifacts}"
: "${MINIO_ROOT_USER:?}"; : "${MINIO_ROOT_PASSWORD:?}"
: "${MINIO_K8S_ACCESS_KEY:?set MINIO_K8S_ACCESS_KEY in .env}"
: "${MINIO_K8S_SECRET_KEY:?set MINIO_K8S_SECRET_KEY in .env}"

# Build the scoped policy from the bucket list, so adding a bucket to .env
# widens the policy in the same edit rather than in a forgotten second one.
resources=""
for b in $MINIO_BUCKETS; do
  resources="$resources\"arn:aws:s3:::$b\",\"arn:aws:s3:::$b/*\","
done
policy="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:*\"],\"Resource\":[${resources%,}]}]}"

# The remote script is fed over stdin, credentials included. Passing them as
# `ssh host "VAR=secret ..."` would put them in the remote argv, where any
# process on the VM can read them out of /proc for the life of the command.
# stdin is only ever visible to the shell reading it.
{
  printf 'MC_HOST_lab=%q\n' "http://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@127.0.0.1:9000"
  printf 'export MC_HOST_lab\n'
  printf 'BUCKETS=%q\n'      "$MINIO_BUCKETS"
  printf 'AK=%q\n'           "$MINIO_K8S_ACCESS_KEY"
  printf 'SK=%q\n'           "$MINIO_K8S_SECRET_KEY"
  printf 'POLICY=%q\n'       "$policy"
  cat <<'REMOTE'
set -euo pipefail

for b in $BUCKETS; do
  if mc ls "lab/$b" >/dev/null 2>&1; then
    echo "bucket $b: exists"
  else
    mc mb "lab/$b"
  fi
  # Versioning on every bucket. It is the difference between "the backup was
  # overwritten" being recoverable and being a postmortem, and it costs nothing
  # until something actually overwrites an object.
  mc version enable "lab/$b" >/dev/null
done

umask 077
printf '%s' "$POLICY" > /tmp/k8s-policy.json
mc admin policy create lab k8s-rw /tmp/k8s-policy.json 2>/dev/null \
  || mc admin policy add lab k8s-rw /tmp/k8s-policy.json
rm -f /tmp/k8s-policy.json

mc admin user add lab "$AK" "$SK" 2>/dev/null || echo "user $AK: exists"
mc admin policy attach lab k8s-rw --user "$AK" 2>/dev/null \
  || mc admin policy set lab k8s-rw "user=$AK" 2>/dev/null \
  || echo "policy k8s-rw: already attached to $AK"

echo
echo "buckets:"
mc ls lab
echo
echo "cluster credential:"
mc admin user info lab "$AK" | sed 's/^/  /'
REMOTE
} | ssh "$MINIO_VM_USER@$MINIO_VM_IP" "bash -s"
