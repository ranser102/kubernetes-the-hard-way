#!/usr/bin/env bash

# ==============================================================================
# KTHW UPGRADE — Step 1: Backup etcd
# Runs on: jumpbox/local machine (executes snapshot on server via SSH)
#
# Always run this before any upgrade. The snapshot is the only way to recover
# if the upgrade fails or corrupts the cluster state.
# ==============================================================================
set -euo pipefail

SSH_KEY="${KTHW_SSH_KEY_PATH:-${HOME}/.ssh/google_compute_engine}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
SNAPSHOT_PATH="/var/lib/etcd-backup/snapshot-${TIMESTAMP}.db"

SSH_OPTS=(
  -i "${SSH_KEY}"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
)

echo "=== [1/2] Taking etcd snapshot on server ==="
# etcdctl snapshot save writes a point-in-time backup of all cluster state.
# The snapshot is stored on the server at /var/lib/etcd-backup/.
ssh "${SSH_OPTS[@]}" root@server bash -s <<REMOTE
set -euo pipefail
mkdir -p /var/lib/etcd-backup
ETCDCTL_API=3 etcdctl snapshot save "${SNAPSHOT_PATH}" \
  --endpoints=http://127.0.0.1:2379
echo "Snapshot saved: ${SNAPSHOT_PATH}"
ETCDCTL_API=3 etcdctl snapshot status "${SNAPSHOT_PATH}" --write-out=table
REMOTE

echo ""
echo "=== [2/2] Copying snapshot to jumpbox ==="
# Pull the snapshot locally so it survives even if the server is lost
LOCAL_BACKUP="${HOME}/kthw-etcd-backups"
mkdir -p "${LOCAL_BACKUP}"
scp "${SSH_OPTS[@]}" \
  "root@server:${SNAPSHOT_PATH}" \
  "${LOCAL_BACKUP}/snapshot-${TIMESTAMP}.db"
echo "Local copy: ${LOCAL_BACKUP}/snapshot-${TIMESTAMP}.db"

echo ""
echo "=== etcd backup complete ==="
echo "To restore if needed:"
echo "  etcdctl snapshot restore ${LOCAL_BACKUP}/snapshot-${TIMESTAMP}.db --data-dir /var/lib/etcd-restore"
echo "Next: run ./scripts/14-upgrade/02-download-new-binaries.sh"
