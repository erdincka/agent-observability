#!/usr/bin/env bash
# Remove the lab from the cluster, leaving the lab's own infrastructure alone.
#
# Written for the one done-criterion phase 1 never verified: that this repository
# rebuilds the lab from nothing. A teardown that leaves debris makes the rebuild
# prove less than it looks like it proves, so the order here matters:
#
#   1. Helm releases first. Deleting a namespace takes the release metadata with
#      it, stranding cluster-scoped RBAC and leaving `helm upgrade --install`
#      to fail later on a release it can no longer see.
#   2. CloudNativePG clusters next, so the operator tears them down itself
#      rather than the namespace delete blocking on its finalizers.
#   3. The namespaces, which take Deployments, StatefulSets, PVCs, Secrets,
#      ConfigMaps, NetworkPolicies and HTTPRoutes with them.
#   4. A check that nothing survived.
#
# Deliberately NOT touched, because this repository declares them as
# prerequisites rather than as the lab: the MinIO VM and its buckets, the
# `platform` Gateway, the CloudNativePG operator, the registry, and Prometheus
# (on the single-VM path, deploy/01-cluster/ installs the cluster-side ones).
#
#   make teardown CONFIRM=yes
set -uo pipefail
cd "$(dirname "$0")/.."

PLATFORM_NS=agent-obs-platform
APP_NS=agent-obs-app
RELEASES=(perses mlflow openlit otel-collector)

if [ "${CONFIRM:-}" != yes ]; then
  echo "This deletes both lab namespaces and every volume in them."
  echo "Nothing is recoverable afterwards except what you have already dumped."
  echo
  echo "Re-run with:  make teardown CONFIRM=yes"
  exit 2
fi

echo "==> what is about to be destroyed"
kubectl get pvc -A --no-headers 2>/dev/null | grep -E "$PLATFORM_NS|$APP_NS" | awk '{printf "    %-20s %-26s %s\n", $1, $2, $4}'

echo
echo "==> 1/4 uninstalling Helm releases"
for rel in "${RELEASES[@]}"; do
  if helm status "$rel" -n "$PLATFORM_NS" >/dev/null 2>&1; then
    helm uninstall "$rel" -n "$PLATFORM_NS" --wait --timeout 3m >/dev/null 2>&1 \
      && echo "    uninstalled $rel" || echo "    WARNING: helm uninstall $rel did not complete cleanly"
  else
    echo "    $rel: not installed"
  fi
done

echo
echo "==> 2/4 deleting CloudNativePG clusters"
for ns in "$PLATFORM_NS" "$APP_NS"; do
  names=$(kubectl get cluster.postgresql.cnpg.io -n "$ns" -o name 2>/dev/null)
  if [ -n "$names" ]; then
    kubectl delete cluster.postgresql.cnpg.io --all -n "$ns" --timeout=180s >/dev/null 2>&1 \
      && echo "    $ns: $(echo "$names" | wc -l | tr -d ' ') cluster(s) deleted" \
      || echo "    WARNING: $ns: cluster delete timed out; the namespace delete will finish it"
  else
    echo "    $ns: none"
  fi
done

echo
echo "==> 3/4 deleting namespaces (this is the slow part)"
kubectl delete namespace "$APP_NS" "$PLATFORM_NS" --ignore-not-found --timeout=300s \
  || echo "    WARNING: namespace delete timed out — check for stuck finalizers below"

echo
echo "==> 4/4 verifying that nothing survived"
status=0
for ns in "$PLATFORM_NS" "$APP_NS"; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    phase=$(kubectl get namespace "$ns" -o jsonpath='{.status.phase}')
    echo "    STILL PRESENT: namespace $ns ($phase)"
    kubectl get namespace "$ns" -o jsonpath='{.spec.finalizers}{"\n"}' | sed 's/^/      finalizers: /'
    status=1
  else
    echo "    gone: namespace $ns"
  fi
done

pvs=$(kubectl get pv -o json 2>/dev/null \
      | python3 -c "import json,sys; print('\n'.join(p['metadata']['name'] for p in json.load(sys.stdin)['items'] if (p['spec'].get('claimRef') or {}).get('namespace') in ('$PLATFORM_NS','$APP_NS')))")
if [ -n "$pvs" ]; then
  echo "    STILL PRESENT: PersistentVolumes still bound to lab namespaces:"; echo "$pvs" | sed 's/^/      /'; status=1
else
  echo "    gone: all PersistentVolumes for both namespaces"
fi

leftovers=$(kubectl get clusterrole,clusterrolebinding -o name 2>/dev/null \
            | grep -E 'otel-collector|openlit|perses|mlflow|agent-obs' || true)
if [ -n "$leftovers" ]; then
  echo "    STILL PRESENT: cluster-scoped objects from the lab's charts:"; echo "$leftovers" | sed 's/^/      /'; status=1
else
  echo "    gone: no cluster-scoped leftovers from the lab's charts"
fi

echo
if [ $status -eq 0 ]; then
  echo "==> teardown complete: the cluster holds nothing of this lab."
  echo "    MinIO, the Gateway and the operators are untouched, as intended."
else
  echo "==> teardown INCOMPLETE — see the entries above before rebuilding."
fi
exit $status
