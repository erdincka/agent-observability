#!/usr/bin/env bash
# Runs ON the k3s VM as root, uploaded there by provision-k3s-vm.sh. Never run
# locally. Idempotent: re-running on an installed node of the same version
# only rewrites the registry file and restarts the service.
#
# Reads from the environment: K3S_VERSION, K3S_NODE_IP, REGISTRY.
set -euo pipefail
: "${K3S_VERSION:?}"; : "${K3S_NODE_IP:?}"; : "${REGISTRY:?}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

say "Waiting for cloud-init to finish"
cloud-init status --wait >/dev/null 2>&1 || true

say "Packages"
# Whatever the template is missing. Debian's cloud image lacks curl; a RHEL
# family image may lack both. Nothing here depends on the distribution beyond
# having one of the two package managers.
need=()
command -v curl >/dev/null || need+=(curl)
if [ "${#need[@]}" -gt 0 ]; then
  if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get -qq update
    DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "${need[@]}"
  elif command -v dnf >/dev/null; then
    dnf -q install -y "${need[@]}"
  else
    echo "ERROR: cannot install ${need[*]}: neither apt-get nor dnf found" >&2; exit 1
  fi
fi

say "Registry: $REGISTRY over plain HTTP"
# containerd defaults to HTTPS for anything that is not localhost. Telling it
# the registry speaks HTTP is the whole of the trust decision here; the
# registry is on a private VLAN, like the lab's original one.
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/registries.yaml <<YAML
mirrors:
  "$REGISTRY":
    endpoint:
      - "http://$REGISTRY"
YAML

say "k3s $K3S_VERSION"
# --disable traefik: the lab exposes its UIs through an Envoy Gateway (see
# prereqs.sh), and on a single node its LoadBalancer Service takes the node's
# port 80 through k3s's ServiceLB. Traefik would hold that port first.
# NetworkPolicy enforcement (kube-router) stays on: chapter 7 depends on it.
if [ -x /usr/local/bin/k3s ] && /usr/local/bin/k3s --version | grep -q "$K3S_VERSION"; then
  echo "k3s $K3S_VERSION already installed — restarting to pick up registries.yaml"
  systemctl restart k3s
else
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server \
    --node-ip "$K3S_NODE_IP" --tls-san "$K3S_NODE_IP" \
    --disable traefik \
    --write-kubeconfig-mode 0600
fi

say "Waiting for the node"
for i in $(seq 1 60); do
  if /usr/local/bin/k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'; then
    echo "ready after ${i} attempts"; break
  fi
  [ "$i" = 60 ] && { echo "ERROR: node not Ready after 5 minutes" >&2; /usr/local/bin/k3s kubectl get nodes; exit 1; }
  sleep 5
done
/usr/local/bin/k3s kubectl wait --for=condition=Available deployment/coredns -n kube-system --timeout=180s >/dev/null
/usr/local/bin/k3s kubectl wait --for=condition=Available deployment/local-path-provisioner -n kube-system --timeout=180s >/dev/null
/usr/local/bin/k3s kubectl get nodes -o wide
/usr/local/bin/k3s kubectl get storageclass
