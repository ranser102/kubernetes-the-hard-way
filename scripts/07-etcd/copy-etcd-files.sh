#!/usr/bin/env bash

# ==============================================================================
# KTHW ETCD — Copy binaries and unit file to server (runs locally)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOWNLOADS_DIR="${ROOT_DIR}/kthw-downloads"
UNITS_DIR="${ROOT_DIR}/units"
SSH_KEY="${KTHW_SSH_KEY_PATH:-${HOME}/.ssh/google_compute_engine}"

FORCE=false
for arg in "$@"; do
  [[ "${arg}" == "--force" ]] && FORCE=true
done

SSH_OPTS=(
  -i "${SSH_KEY}"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
)

echo "=== [1/2] Copying etcd binaries and unit file to server ==="

_remote_file_exists() {
  local host="$1" path="$2"
  ssh "${SSH_OPTS[@]}" "root@${host}" "test -f '${path}'" 2>/dev/null
}

for src_path in \
  "${DOWNLOADS_DIR}/controller/etcd" \
  "${DOWNLOADS_DIR}/client/etcdctl" \
  "${UNITS_DIR}/etcd.service"; do

  filename="$(basename "${src_path}")"

  if ! ${FORCE} && _remote_file_exists "server" "~/${filename}"; then
    echo "Already exists on server: ~/${filename} — skipping."
  else
    scp "${SSH_OPTS[@]}" "${src_path}" root@server:~/
    echo "Copied: ${filename}"
  fi
done

echo "=== [2/2] Verifying files are present on server ==="
ssh "${SSH_OPTS[@]}" root@server \
  "ls -lh ~/etcd ~/etcdctl ~/etcd.service"

echo "=== etcd files are ready on server ==="
echo "Next: run ./scripts/07-etcd/bootstrap-etcd.sh"
