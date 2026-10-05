#!/usr/bin/env bash
# Creates (or re-provisions) the standalone MinIO VM on the Proxmox host.
#
# MinIO lives outside Kubernetes on purpose. It is meant to be the durable thing
# the cluster leans on, and a store that is scheduled by the cluster it backs
# cannot serve that role — a rebuild of k3s would take its own backups with it.
# Putting it on the hypervisor makes the dependency point one way.
#
# Run from the repository root:  make minio-vm
#
# Safe to re-run. An existing VM is not recreated; the installer is re-uploaded
# and re-run, which upgrades the binary and rewrites the unit but never touches
# the data disk.
set -euo pipefail
cd "$(dirname "$0")/../.."

set -a; . ./.env; set +a

# --- shape, overridable from .env -------------------------------------------
# Hypervisor, template and pool are properties of wherever this runs, so they
# come from .env; the defaults below are only the original lab's values.
PVE_HOST="${PVE_HOST:-pve}"
PVE_TEMPLATE_VMID="${PVE_TEMPLATE_VMID:-9000}"
PVE_STORAGE="${PVE_STORAGE:-local-lvm}"
MINIO_VMID="${MINIO_VMID:-1040}"
MINIO_VM_NAME="${MINIO_VM_NAME:-minio}"
MINIO_VM_IP="${MINIO_VM_IP:-10.1.1.20}"
MINIO_VM_CIDR="${MINIO_VM_CIDR:-${VM_CIDR:-24}}"
MINIO_VM_GW="${MINIO_VM_GW:-${VM_GW:-10.1.1.1}}"
MINIO_VM_DNS="${MINIO_VM_DNS:-${VM_DNS:-$MINIO_VM_GW}}"
MINIO_VM_CORES="${MINIO_VM_CORES:-4}"
MINIO_VM_MEMORY="${MINIO_VM_MEMORY:-8192}"
MINIO_VM_BOOT_GB="${MINIO_VM_BOOT_GB:-32}"
MINIO_VM_DATA_GB="${MINIO_VM_DATA_GB:-500}"
MINIO_VM_USER="${MINIO_VM_USER:-${VM_USER:-ubuntu}}"
MINIO_VM_SSHKEY="${MINIO_VM_SSHKEY:-${VM_SSHKEY:-$HOME/.ssh/id_rsa.pub}}"

# Pinned, with checksums, because "latest" makes a rebuild a different build.
MINIO_VERSION="${MINIO_VERSION:-RELEASE.2025-09-07T16-13-09Z}"
MINIO_SHA256="${MINIO_SHA256:-7c5bd8512c6e966455b1d198209358b2d191c77a83ab377c4073281065fb855f}"
MC_VERSION="${MC_VERSION:-RELEASE.2025-08-13T08-35-41Z}"
MC_SHA256="${MC_SHA256:-01f866e9c5f9b87c2b09116fa5d7c06695b106242d829a8bb32990c00312e891}"

: "${MINIO_ROOT_USER:?set MINIO_ROOT_USER in .env}"
: "${MINIO_ROOT_PASSWORD:?set MINIO_ROOT_PASSWORD in .env}"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
pve()  { ssh "$PVE_HOST" "$@"; }

[ -f "$MINIO_VM_SSHKEY" ] || { echo "ERROR: no public key at $MINIO_VM_SSHKEY" >&2; exit 1; }

say "Checking the Proxmox host"
pve "qm status $PVE_TEMPLATE_VMID >/dev/null" \
  || { echo "ERROR: template VM $PVE_TEMPLATE_VMID not found on $PVE_HOST" >&2; exit 1; }

if pve "qm status $MINIO_VMID >/dev/null 2>&1"; then
  echo "VM $MINIO_VMID already exists — skipping create, re-running the installer"
  pve "qm status $MINIO_VMID | grep -q running || qm start $MINIO_VMID"
else
  # Only meaningful before the VM exists: afterwards its own address answers.
  if ping -c1 -W2 "$MINIO_VM_IP" >/dev/null 2>&1; then
    echo "ERROR: $MINIO_VM_IP already answers ping — pick another MINIO_VM_IP" >&2
    exit 1
  fi

  say "Cloning template $PVE_TEMPLATE_VMID -> $MINIO_VMID ($MINIO_VM_NAME)"
  # Full clone, not linked: this VM outliving the template it came from is the
  # entire point of putting the object store outside the cluster.
  pve "qm clone $PVE_TEMPLATE_VMID $MINIO_VMID \
        --name $MINIO_VM_NAME --full --storage $PVE_STORAGE"

  say "Configuring hardware and cloud-init"
  scp -q "$MINIO_VM_SSHKEY" "$PVE_HOST:/tmp/minio-vm.pub"
  pve "qm set $MINIO_VMID \
        --cores $MINIO_VM_CORES --memory $MINIO_VM_MEMORY --cpu host \
        --onboot 1 --agent enabled=1 \
        --ciuser $MINIO_VM_USER --sshkeys /tmp/minio-vm.pub \
        --nameserver $MINIO_VM_DNS --searchdomain local \
        --ipconfig0 ip=$MINIO_VM_IP/$MINIO_VM_CIDR,gw=$MINIO_VM_GW"
  pve "rm -f /tmp/minio-vm.pub"

  say "Sizing disks: boot ${MINIO_VM_BOOT_GB}G, data ${MINIO_VM_DATA_GB}G"
  pve "qm resize $MINIO_VMID scsi0 ${MINIO_VM_BOOT_GB}G"
  # Separate disk rather than a directory on the root volume, so the object
  # store can be grown, snapshotted or detached without touching the OS.
  pve "qm set $MINIO_VMID --scsi1 $PVE_STORAGE:${MINIO_VM_DATA_GB},discard=on,ssd=1"

  say "Starting VM $MINIO_VMID"
  pve "qm start $MINIO_VMID"
fi

say "Waiting for SSH on $MINIO_VM_IP"
for i in $(seq 1 90); do
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
        "$MINIO_VM_USER@$MINIO_VM_IP" true 2>/dev/null; then
    echo "up after ${i} attempts"; break
  fi
  [ "$i" = 90 ] && { echo "ERROR: no SSH on $MINIO_VM_IP after 90 attempts" >&2; exit 1; }
  sleep 5
done

say "Installing MinIO on $MINIO_VM_IP"
# The installer itself holds no secrets, so it can travel by scp.
scp -q deploy/05-minio/install-minio.sh "$MINIO_VM_USER@$MINIO_VM_IP:/tmp/install-minio.sh"
# Its inputs go over stdin and are sourced by the root shell — never onto the
# command line. The previous version passed them as `sudo -E env
# MINIO_ROOT_PASSWORD='...' bash ...` under a comment claiming "never into an
# argv". It was argv, and sudo writes every command line it runs to the journal
# and /var/log/auth.log (syslog:adm 0640), so the root password sat in both,
# readable by the adm group. Now sudo logs only the fixed `bash -c` string below.
# Same pattern as bootstrap-buckets.sh. TODO.md item 5 covers the credential
# that already leaked.
{
  printf 'MINIO_ROOT_USER=%q\n'     "$MINIO_ROOT_USER"
  printf 'MINIO_ROOT_PASSWORD=%q\n' "$MINIO_ROOT_PASSWORD"
  printf 'MINIO_VERSION=%q\n'       "$MINIO_VERSION"
  printf 'MINIO_SHA256=%q\n'        "$MINIO_SHA256"
  printf 'MC_VERSION=%q\n'          "$MC_VERSION"
  printf 'MC_SHA256=%q\n'           "$MC_SHA256"
  printf 'MINIO_FORCE_FORMAT=%q\n'  "${MINIO_FORCE_FORMAT:-0}"
} | ssh "$MINIO_VM_USER@$MINIO_VM_IP" \
  "sudo bash -c 'set -a; . /dev/stdin; set +a; bash /tmp/install-minio.sh </dev/null && rm -f /tmp/install-minio.sh'"

say "MinIO is up"
echo "  S3 API   http://$MINIO_VM_IP:9000"
echo "  Console  http://$MINIO_VM_IP:9001"
