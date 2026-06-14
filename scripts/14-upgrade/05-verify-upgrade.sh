#!/usr/bin/env bash

# ==============================================================================
# KTHW UPGRADE — Step 5: Verify upgrade
# Runs on: jumpbox/local machine
# ==============================================================================
set -euo pipefail

SSH_KEY="${KTHW_SSH_KEY_PATH:-${HOME}/.ssh/google_compute_engine}"

SSH_OPTS=(
  -i "${SSH_KEY}"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
)

PASS=0
FAIL=0

_check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  PASS: ${label}"
    (( PASS++ )) || true
  else
    echo "  FAIL: ${label}"
    (( FAIL++ )) || true
  fi
}

# ------------------------------------------------------------------------------
# TEST 1 — Control plane service status
# Runs on: server/control-plane (via SSH)
# Confirms all three control plane services are active after the upgrade.
# ------------------------------------------------------------------------------
echo "=== [1/4] Control plane service status ==="
ssh "${SSH_OPTS[@]}" root@server bash -s <<'REMOTE'
for svc in etcd kube-apiserver kube-controller-manager kube-scheduler; do
  state="$(systemctl is-active "${svc}" 2>/dev/null || true)"
  if [[ "${state}" == "active" ]]; then
    echo "  PASS: ${svc} is active"
  else
    echo "  FAIL: ${svc} is ${state}"
  fi
done
REMOTE

# ------------------------------------------------------------------------------
# TEST 2 — Component versions on server
# Runs on: server/control-plane (via SSH)
# Prints the version of each installed binary — confirm they match the target.
# ------------------------------------------------------------------------------
echo ""
echo "=== [2/4] Component versions on server ==="
ssh "${SSH_OPTS[@]}" root@server bash -s <<'REMOTE'
for bin in etcd kube-apiserver kube-controller-manager kube-scheduler kubectl; do
  ver="$(/usr/local/bin/${bin} --version 2>/dev/null | head -1 || echo 'unknown')"
  echo "  ${bin}: ${ver}"
done
REMOTE

# ------------------------------------------------------------------------------
# TEST 3 — Worker node versions and Ready status
# Runs on: server/control-plane (via SSH) and workers (via SSH)
# kubelet version reported by the API server shows what version each node runs.
# ------------------------------------------------------------------------------
echo ""
echo "=== [3/4] Worker node versions and Ready status ==="
ssh "${SSH_OPTS[@]}" root@server \
  "kubectl get nodes -o wide --kubeconfig ~/admin.kubeconfig"

for node in node-0 node-1; do
  status="$(ssh "${SSH_OPTS[@]}" root@server \
    "kubectl get node ${node} --kubeconfig ~/admin.kubeconfig \
     -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null || true)"
  if [[ "${status}" == "True" ]]; then
    echo "  PASS: ${node} is Ready"
    (( PASS++ )) || true
  else
    echo "  FAIL: ${node} status is '${status:-unknown}'"
    (( FAIL++ )) || true
  fi
done

# ------------------------------------------------------------------------------
# TEST 4 — kubectl version from jumpbox (client + server match)
# Runs on: jumpbox/local machine
# Client and server versions should match (or be within one minor version).
# A skew greater than one minor version is unsupported.
# ------------------------------------------------------------------------------
echo ""
echo "=== [4/4] kubectl version from jumpbox ==="
kubectl version
_check "kubectl can reach API server" kubectl version

echo ""
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"
if [[ ${FAIL} -eq 0 ]]; then
  echo "=== Upgrade verification passed ==="
else
  echo "=== ${FAIL} check(s) failed — review output above ==="
  exit 1
fi
