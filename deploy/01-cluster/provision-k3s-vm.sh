#!/usr/bin/env bash
# Creates (or re-provisions) a single-VM k3s cluster on the Proxmox host, and
# writes its kubeconfig where .env says (KUBECONFIG).
#
# The guide was first built on a three-node cluster that already existed. This
# is the single-machine path: one VM, one node, the same manifests. Nothing
# about the hypervisor is assumed beyond "a cloud-init template to clone and a
# storage pool to clone it onto", and both come from .env.
#
# Run from the repository root:  make k3s-vm
#
# Safe to re-run. An existing VM is not recreated; the installer is re-uploaded
# and re-run, which is a no-op on an installed node of the same version.
set -euo pipefail
cd "$(dirname "$0")/../.."

set -a; . ./.env; set +a

# --- shape, overridable from .env -------------------------------------------
PVE_HOST="${PVE_HOST:-pve}"
PVE_TEMPLATE_VMID="${PVE_TEMPLATE_VMID:-9000}"
PVE_STORAGE="${PVE_STORAGE:-local-lvm}"
K3S_VMID="${K3S_VMID:-1041}"
K3S_VM_NAME="${K3S_VM_NAME:-agent-obs-k3s}"
K3S_VM_IP="${K3S_VM_IP:?set K3S_VM_IP in .env}"
K3S_VM_CIDR="${K3S_VM_CIDR:-${VM_CIDR:-24}}"
K3S_VM_GW="${K3S_VM_GW:-${VM_GW:-10.1.1.1}}"
K3S_VM_DNS="${K3S_VM_DNS:-${VM_DNS:-$K3S_VM_GW}}"
K3S_VM_CORES="${K3S_VM_CORES:-12}"
K3S_VM_MEMORY="${K3S_VM_MEMORY:-32768}"
K3S_VM_DISK_GB="${K3S_VM_DISK_GB:-160}"
K3S_VM_USER="${K3S_VM_USER:-${VM_USER:-ubuntu}}"
K3S_VM_SSHKEY="${K3S_VM_SSHKEY:-${VM_SSHKEY:-$HOME/.ssh/id_rsa.pub}}"
K3S_VERSION="${K3S_VERSION:-v1.36.5+k3s1}"
REGISTRY="${REGISTRY:?set REGISTRY in .env}"
KUBECONFIG_OUT="${KUBECONFIG:-./kubeconfig-$K3S_VM_NAME}"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
pve()  { ssh "$PVE_HOST" "$@"; }
vm()   { ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$K3S_VM_USER@$K3S_VM_IP" "$@"; }

[ -f "$K3S_VM_SSHKEY" ] || { echo "ERROR: no public key at $K3S_VM_SSHKEY" >&2; exit 1; }

say "Checking the Proxmox host"
pve "qm status $PVE_TEMPLATE_VMID >/dev/null" \
  || { echo "ERROR: template VM $PVE_TEMPLATE_VMID not found on $PVE_HOST" >&2; exit 1; }

if pve "qm status $K3S_VMID >/dev/null 2>&1"; then
  echo "VM $K3S_VMID already exists — skipping create, re-running the installer"
  pve "qm status $K3S_VMID | grep -q running || qm start $K3S_VMID"
else
  if ping -c1 -W2 "$K3S_VM_IP" >/dev/null 2>&1; then
    echo "ERROR: $K3S_VM_IP already answers ping — pick another K3S_VM_IP" >&2
    exit 1
  fi

  say "Cloning template $PVE_TEMPLATE_VMID -> $K3S_VMID ($K3S_VM_NAME)"
  pve "qm clone $PVE_TEMPLATE_VMID $K3S_VMID \
        --name $K3S_VM_NAME --full --storage $PVE_STORAGE"

  say "Configuring hardware and cloud-init: $K3S_VM_CORES cores, ${K3S_VM_MEMORY}M, $K3S_VM_IP"
  scp -q "$K3S_VM_SSHKEY" "$PVE_HOST:/tmp/k3s-vm.pub"
  pve "qm set $K3S_VMID \
        --cores $K3S_VM_CORES --memory $K3S_VM_MEMORY --cpu host \
        --onboot 1 --agent enabled=1 \
        --ciuser $K3S_VM_USER --sshkeys /tmp/k3s-vm.pub \
        --nameserver $K3S_VM_DNS --searchdomain local \
        --ipconfig0 ip=$K3S_VM_IP/$K3S_VM_CIDR,gw=$K3S_VM_GW"
  pve "rm -f /tmp/k3s-vm.pub"

  say "Sizing the disk: ${K3S_VM_DISK_GB}G"
  # One disk. local-path provisions every PVC as a directory on it, and
  # local-path cannot grow a volume later, so size this for the whole lab.
  pve "qm resize $K3S_VMID scsi0 ${K3S_VM_DISK_GB}G"

  say "Starting VM $K3S_VMID"
  pve "qm start $K3S_VMID"
fi

say "Waiting for SSH on $K3S_VM_IP"
for i in $(seq 1 90); do
  if vm -o ConnectTimeout=5 true 2>/dev/null; then echo "up after ${i} attempts"; break; fi
  [ "$i" = 90 ] && { echo "ERROR: no SSH on $K3S_VM_IP after 90 attempts" >&2; exit 1; }
  sleep 5
done

say "Installing k3s $K3S_VERSION on $K3S_VM_IP"
scp -q deploy/01-cluster/install-k3s.sh "$K3S_VM_USER@$K3S_VM_IP:/tmp/install-k3s.sh"
{
  printf 'K3S_VERSION=%q\n' "$K3S_VERSION"
  printf 'K3S_NODE_IP=%q\n'  "$K3S_VM_IP"
  printf 'REGISTRY=%q\n'     "$REGISTRY"
} | vm "sudo bash -c 'set -a; . /dev/stdin; set +a; bash /tmp/install-k3s.sh </dev/null && rm -f /tmp/install-k3s.sh'"

say "Writing the kubeconfig to $KUBECONFIG_OUT"
# The node's own file points at 127.0.0.1; the copy on the workstation points
# at the VM. Context, cluster and user are named after the VM so this file is
# recognisable next to any other kubeconfig.
umask 077
vm "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed -e "s|https://127.0.0.1:6443|https://$K3S_VM_IP:6443|" \
        -e "s|: default$|: $K3S_VM_NAME|" \
  > "$KUBECONFIG_OUT"
umask 022

say "Cluster"
KUBECONFIG="$KUBECONFIG_OUT" kubectl get nodes -o wide
[ -n "${KUBECONFIG:-}" ] || echo "NOTE: set KUBECONFIG=$KUBECONFIG_OUT in .env so make targets use this cluster"
echo
echo "Next: make cluster-prereqs"
