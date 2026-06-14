#!/usr/bin/env bash

# ==============================================================================
# KTHW UPGRADE — Step 3: Upgrade control plane (server)
# Runs on: jumpbox/local machine (executes commands on server via SSH)
#
# Upgrade order is strict:
#   1. etcd          — must be upgraded first; API server depends on it
#   2. kube-apiserver — cluster is briefly unavailable during restart
#   3. kube-controller-manager + kube-scheduler — order between these is flexible
#
# The API server must always be >= the version of other control plane components.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOWNLOADS_DIR="${ROOT_DIR}/kthw-downloads"
SSH_KEY="${KTHW_SSH_KEY_PATH:-${HOME}/.ssh/google_compute_engine}"

SSH_OPTS=(
  -i "${SSH_KEY}"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
)

_remote_run() {
  ssh "${SSH_OPTS[@]}" root@server bash -s "$@"
}

# ------------------------------------------------------------------------------
# Copy new binaries to server
# ------------------------------------------------------------------------------
echo "=== [1/4] Copying new control plane binaries to server ==="
for binary in etcd etcdctl kube-apiserver kube-controller-manager kube-scheduler kubectl; do
  src="${DOWNLOADS_DIR}/controller/${binary}"
  [[ ! -f "${src}" ]] && src="${DOWNLOADS_DIR}/client/${binary}"
  echo "  Copying ${binary}..."
  scp "${SSH_OPTS[@]}" "${src}" "root@server:~/${binary}"
done

# ------------------------------------------------------------------------------
# Upgrade etcd first — stop, replace binary, start, verify
# ------------------------------------------------------------------------------
echo ""
echo "=== [2/4] Upgrading etcd ==="
_remote_run <<'REMOTE'
set -euo pipefail
echo "  Stopping etcd..."
systemctl stop etcd

echo "  Installing new etcd binary..."
mv -f ~/etcd ~/etcdctl /usr/local/bin/
chmod +x /usr/local/bin/etcd /usr/local/bin/etcdctl

echo "  Starting etcd..."
systemctl start etcd

echo "  Waiting for etcd to be ready..."
for i in $(seq 1 15); do
  systemctl is-active --quiet etcd && break
  sleep 1
done
systemctl is-active --quiet etcd || {
  journalctl -xeu etcd --no-pager | tail -20
  exit 1
}
echo "  etcd is running: $(etcd --version | head -1)"
etcdctl member list
REMOTE

# ------------------------------------------------------------------------------
# Upgrade kube-apiserver — brief API unavailability expected during restart
# ------------------------------------------------------------------------------
echo ""
echo "=== [3/4] Upgrading kube-apiserver ==="
_remote_run <<'REMOTE'
set -euo pipefail
echo "  Stopping kube-apiserver (cluster briefly unavailable)..."
systemctl stop kube-apiserver

echo "  Installing new kube-apiserver binary..."
mv -f ~/kube-apiserver /usr/local/bin/
chmod +x /usr/local/bin/kube-apiserver

echo "  Starting kube-apiserver..."
systemctl start kube-apiserver

echo "  Waiting up to 20s for kube-apiserver to initialize..."
for i in $(seq 1 20); do
  systemctl is-active --quiet kube-apiserver && break
  sleep 1
done
systemctl is-active --quiet kube-apiserver || {
  journalctl -xeu kube-apiserver --no-pager | tail -20
  exit 1
}
echo "  kube-apiserver is running: $(kube-apiserver --version)"
REMOTE

# ------------------------------------------------------------------------------
# Upgrade kube-controller-manager and kube-scheduler
# ------------------------------------------------------------------------------
echo ""
echo "=== [4/4] Upgrading kube-controller-manager and kube-scheduler ==="
_remote_run <<'REMOTE'
set -euo pipefail
for svc in kube-controller-manager kube-scheduler; do
  bin="${svc}"
  echo "  Stopping ${svc}..."
  systemctl stop "${svc}"

  echo "  Installing new ${bin} binary..."
  mv -f ~/"${bin}" /usr/local/bin/
  chmod +x /usr/local/bin/"${bin}"

  echo "  Starting ${svc}..."
  systemctl start "${svc}" || {
    journalctl -xeu "${svc}" --no-pager | tail -20
    exit 1
  }
  echo "  ${svc} is running: $(/usr/local/bin/${bin} --version)"
done

# Also replace kubectl on the server
mv -f ~/kubectl /usr/local/bin/
chmod +x /usr/local/bin/kubectl
echo "  kubectl updated: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
REMOTE

echo ""
echo "=== Control plane upgrade complete ==="
echo "Next: run ./scripts/14-upgrade/04-upgrade-workers.sh"
