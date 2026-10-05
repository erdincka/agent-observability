#!/usr/bin/env bash
# Runs ON the MinIO VM, uploaded there by provision-vm.sh. Never run locally.
#
# Everything this script does is idempotent: re-running it upgrades the binary
# and rewrites the unit without touching the data disk. The one destructive
# operation — formatting the data disk — refuses to proceed unless the disk is
# genuinely blank, and even then only under an explicit flag.
#
# Reads from the environment: MINIO_ROOT_USER, MINIO_ROOT_PASSWORD,
# MINIO_VERSION, MC_VERSION, MINIO_SHA256, MC_SHA256, MINIO_FORCE_FORMAT.
set -euo pipefail

: "${MINIO_ROOT_USER:?}"
: "${MINIO_ROOT_PASSWORD:?}"
: "${MINIO_VERSION:?}"
: "${MC_VERSION:?}"
: "${MINIO_SHA256:?}"
: "${MC_SHA256:?}"

MOUNT=/mnt/minio/disk1
say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

say "Waiting for cloud-init to finish"
cloud-init status --wait >/dev/null 2>&1 || true

say "Packages"
# Whatever the template is missing. Ubuntu's cloud image has xfsprogs; Debian's
# does not, and the first run on a Debian 13 template died here with
# "mkfs.xfs: command not found". Nothing below depends on the distribution
# beyond having one of the two package managers.
need=()
command -v mkfs.xfs >/dev/null || need+=(xfsprogs)
command -v curl     >/dev/null || need+=(curl)
if [ "${#need[@]}" -gt 0 ]; then
  echo "installing: ${need[*]}"
  if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get -qq update
    DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "${need[@]}"
  elif command -v dnf >/dev/null; then
    dnf -q install -y "${need[@]}"
  else
    echo "ERROR: cannot install ${need[*]}: neither apt-get nor dnf found" >&2; exit 1
  fi
else
  echo "xfsprogs and curl present"
fi

say "Locating the data disk"
# The boot disk is whichever disk carries /. Anything else that is a whole disk
# and not removable is a candidate; we require exactly one, because guessing
# which of several to format is not a decision a script should make.
root_src=$(findmnt -no SOURCE /)
root_disk=$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)
[ -z "$root_disk" ] && root_disk=$(basename "$root_src" | sed 's/[0-9]*$//')

candidates=()
while read -r name type; do
  [ "$type" = disk ] || continue
  [ "$name" = "$root_disk" ] && continue
  case "$name" in loop*|sr*|zram*) continue ;; esac
  candidates+=("$name")
done < <(lsblk -dno NAME,TYPE)

if [ "${#candidates[@]}" -ne 1 ]; then
  echo "ERROR: expected exactly one non-boot disk, found ${#candidates[@]}: ${candidates[*]:-none}" >&2
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT >&2
  exit 1
fi
DATA_DISK="/dev/${candidates[0]}"
echo "boot disk: /dev/$root_disk    data disk: $DATA_DISK"

say "Preparing $DATA_DISK"
existing_fs=$(lsblk -no FSTYPE "$DATA_DISK" | tr -d '[:space:]')
existing_parts=$(lsblk -no NAME "$DATA_DISK" | tail -n +2 | wc -l)

if [ "$existing_fs" = xfs ]; then
  echo "already XFS — leaving it alone"
elif [ -n "$existing_fs" ] || [ "$existing_parts" -gt 0 ]; then
  if [ "${MINIO_FORCE_FORMAT:-0}" = 1 ]; then
    echo "WARNING: $DATA_DISK holds data (fs='$existing_fs', parts=$existing_parts); MINIO_FORCE_FORMAT=1 given"
    mkfs.xfs -f -L minio-disk1 "$DATA_DISK"
  else
    echo "ERROR: $DATA_DISK is not blank (fs='$existing_fs', partitions=$existing_parts)." >&2
    echo "       Refusing to format. Re-run with MINIO_FORCE_FORMAT=1 to overwrite it." >&2
    exit 1
  fi
else
  # MinIO wants a bare filesystem, not a partition table — one disk, one XFS,
  # which is also what its own deployment guide asks for. XFS rather than ext4
  # because that is the filesystem MinIO tests and tunes against.
  mkfs.xfs -L minio-disk1 "$DATA_DISK"
fi

mkdir -p "$MOUNT"
uuid=$(blkid -s UUID -o value "$DATA_DISK")
# By UUID, not by /dev/sdb: device names are assigned in discovery order and a
# future disk addition would silently reorder them. `nofail` so a missing data
# disk degrades to a failed MinIO rather than an unbootable VM.
if ! grep -q "$uuid" /etc/fstab; then
  echo "UUID=$uuid $MOUNT xfs defaults,noatime,nofail 0 2" >> /etc/fstab
fi
systemctl daemon-reload
mountpoint -q "$MOUNT" || mount "$MOUNT"
df -h "$MOUNT"

say "Installing MinIO $MINIO_VERSION"
# From GitHub Releases, not dl.min.io. On 2026-10-05 every path under
# dl.min.io answered 410 Gone, archive included, and the newest release on
# GitHub (RELEASE.2025-10-15) carries no binaries at all. The pinned release
# still has its assets on GitHub, with the same checksum the lab recorded from
# dl.min.io, so the pin and the checksum below are unchanged.
minio_url="${MINIO_URL:-https://github.com/minio/minio/releases/download/$MINIO_VERSION/minio.linux-amd64.$MINIO_VERSION}"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/minio" "$minio_url"
echo "$MINIO_SHA256  $tmp/minio" | sha256sum -c -
install -m 0755 "$tmp/minio" /usr/local/bin/minio

say "Installing mc $MC_VERSION"
mc_url="${MC_URL:-https://github.com/minio/mc/releases/download/$MC_VERSION/mc.linux-amd64.$MC_VERSION}"
curl -fsSL -o "$tmp/mc" "$mc_url"
echo "$MC_SHA256  $tmp/mc" | sha256sum -c -
install -m 0755 "$tmp/mc" /usr/local/bin/mc

say "Service account and configuration"
id -u minio-user >/dev/null 2>&1 || useradd -r -s /sbin/nologin -d /mnt/minio minio-user
chown -R minio-user:minio-user /mnt/minio

# 0600 root-owned: the systemd unit reads it as root before dropping to
# minio-user, so the credentials never need to be readable by the service user.
umask 077
cat > /etc/default/minio <<EOF
# Written by deploy/05-minio/install-minio.sh from the repository's .env.
# Not the source of truth — edit .env and re-run \`make minio-vm\`.
MINIO_VOLUMES="$MOUNT"
MINIO_OPTS="--address :9000 --console-address :9001"
MINIO_ROOT_USER="$MINIO_ROOT_USER"
MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD"
# Emitted so the cluster's Prometheus can scrape without a bearer token. This
# is a private VLAN lab; on a real estate this would stay authenticated.
MINIO_PROMETHEUS_AUTH_TYPE="public"
EOF
chmod 0600 /etc/default/minio
umask 022

cat > /etc/systemd/system/minio.service <<'EOF'
[Unit]
Description=MinIO object storage
Documentation=https://docs.min.io
Wants=network-online.target
After=network-online.target
# Without this the service starts against an empty /mnt/minio/disk1 before the
# data disk mounts, and MinIO happily initialises a fresh backend on the root
# filesystem. AssertPathIsMountPoint makes that failure loud instead of silent.
AssertPathIsMountPoint=/mnt/minio/disk1

[Service]
Type=notify
User=minio-user
Group=minio-user
EnvironmentFile=/etc/default/minio
ExecStart=/usr/local/bin/minio server $MINIO_OPTS $MINIO_VOLUMES
Restart=always
RestartSec=5s
LimitNOFILE=1048576
TasksMax=infinity
OOMScoreAdjust=-1000
SendSIGKILL=no

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable minio >/dev/null
systemctl restart minio

say "Waiting for the S3 endpoint"
for i in $(seq 1 60); do
  if curl -fsS -o /dev/null http://127.0.0.1:9000/minio/health/live; then
    echo "healthy after ${i}s"
    /usr/local/bin/minio --version
    exit 0
  fi
  sleep 1
done
echo "ERROR: MinIO did not become healthy in 60s" >&2
journalctl -u minio --no-pager -n 40 >&2
exit 1
