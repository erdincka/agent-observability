#!/usr/bin/env bash
# Installs what the manifests under deploy/ assume is already in the cluster.
#
# On the lab this guide was first built on, these pre-existed from other work
# (LEARNINGS.md, 2026-09-09 inventory). On a fresh single-VM cluster they do
# not, so this is the honest list — each one is referenced by a manifest here:
#
#   Envoy Gateway        the HTTPRoutes attach to Gateway `platform` in
#                        namespace `gateway`, listener `web`, *.kube.local
#   CloudNativePG        the three `Cluster` manifests (workflow-db, litellm-db,
#                        mlflow-db)
#   kube-prometheus-stack  mcp-metrics queries
#                        kube-prometheus-stack-prometheus.observability:9090
#
# Not installed, because nothing here needs it: cert-manager (no TLS in the
# lab) and MetalLB (on a single node, k3s's ServiceLB gives the Gateway the
# node's own address). Versions are pinned; see the table in README.md.
#
# Run from the repository root:  make cluster-prereqs      Idempotent.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ -f .env ] && { set -a; . ./.env; set +a; }

ENVOY_GATEWAY_VERSION="${ENVOY_GATEWAY_VERSION:-v1.9.2}"
CNPG_CHART_VERSION="${CNPG_CHART_VERSION:-0.29.0}"            # operator 1.30.0, as on the original lab
KPS_CHART_VERSION="${KPS_CHART_VERSION:-91.9.0}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

say "Cluster"
kubectl cluster-info | head -1
kubectl get storageclass -o name | grep -q local-path \
  || { echo "ERROR: no local-path StorageClass; the manifests size volumes for it" >&2; exit 1; }

say "Helm repositories"
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo add openlit https://openlit.github.io/helm/ >/dev/null 2>&1 || true
helm repo add perses https://perses.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add community-charts https://community-charts.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
echo "cnpg, prometheus-community, open-telemetry, openlit, perses, community-charts"

say "Envoy Gateway $ENVOY_GATEWAY_VERSION"
# The chart carries the Gateway API CRDs. --skip-crds is deliberately not
# passed: on a fresh cluster they have to come from somewhere.
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "$ENVOY_GATEWAY_VERSION" \
  --namespace envoy-gateway-system --create-namespace \
  --wait --timeout 5m
kubectl wait --for=condition=Available deployment/envoy-gateway -n envoy-gateway-system --timeout=180s >/dev/null
kubectl apply -f deploy/01-cluster/gateway.yaml
echo "waiting for Gateway platform to be programmed"
kubectl wait --for=condition=Programmed gateway/platform -n gateway --timeout=180s >/dev/null
addr=$(kubectl get gateway platform -n gateway -o jsonpath='{.status.addresses[0].value}')
echo "Gateway platform: ${addr:-no address yet} (*.kube.local)"
if [ -n "${GATEWAY_IP:-}" ] && [ -n "$addr" ] && [ "$addr" != "$GATEWAY_IP" ]; then
  echo "WARNING: .env says GATEWAY_IP=$GATEWAY_IP but the Gateway is at $addr — fix .env" >&2
fi

say "CloudNativePG (chart $CNPG_CHART_VERSION)"
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --version "$CNPG_CHART_VERSION" \
  --namespace cnpg-system --create-namespace \
  --wait --timeout 5m
kubectl wait --for=condition=Available deployment/cnpg-cloudnative-pg -n cnpg-system --timeout=180s >/dev/null
echo "operator $(kubectl get deployment cnpg-cloudnative-pg -n cnpg-system -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')"

say "kube-prometheus-stack (chart $KPS_CHART_VERSION) in observability"
# Release name is load-bearing: the Service is <release>-prometheus and
# deploy/80-mcp/servers.yaml names it.
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version "$KPS_CHART_VERSION" \
  --namespace observability --create-namespace \
  --values deploy/01-cluster/kube-prometheus-stack.values.yaml \
  --wait --timeout 10m
kubectl get svc kube-prometheus-stack-prometheus -n observability -o name >/dev/null

say "Ready"
kubectl get gateway -n gateway
echo
echo "Next: make step1"
