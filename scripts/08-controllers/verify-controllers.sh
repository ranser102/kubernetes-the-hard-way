#!/usr/bin/env bash

# ==============================================================================
# KTHW CONTROL PLANE — Verification (runs locally)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CERTS_DIR="${ROOT_DIR}/scripts/certs"
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
#
# Verifies that all three control plane systemd services are in the "active"
# (running) state on the server. A service that failed to start, is stuck in
# "activating", or has crashed and not restarted will be reported as FAIL.
#
# Services checked:
#   kube-apiserver          — serves the Kubernetes REST API on port 6443
#   kube-controller-manager — runs reconciliation loops (deployments, nodes…)
#   kube-scheduler          — assigns pods to nodes
# ------------------------------------------------------------------------------
echo "=== [1/4] Control plane service status ==="
ssh "${SSH_OPTS[@]}" root@server bash -s <<'REMOTE'
for svc in kube-apiserver kube-controller-manager kube-scheduler; do
  state="$(systemctl is-active "${svc}" 2>/dev/null || true)"
  if [[ "${state}" == "active" ]]; then
    echo "  PASS: ${svc} is active"
  else
    echo "  FAIL: ${svc} is ${state}"
  fi
done
REMOTE

# ------------------------------------------------------------------------------
# TEST 2 — API server /version endpoint reachable over HTTPS
# Runs on: jumpbox/local machine (curl executed locally)
#
# Issues a TLS-verified HTTPS request from the jumpbox/local machine to the API
# server through the server's external IP (resolved via /etc/hosts). Uses the
# cluster CA cert to validate the server certificate — confirming that:
#   - Port 6443 is reachable from the jumpbox/local machine
#   - The TLS certificate presented by kube-apiserver is signed by the cluster CA
#   - The API server is healthy enough to respond to unauthenticated /version
# ------------------------------------------------------------------------------
echo ""
echo "=== [2/4] API server version (via HTTPS from jumpbox/local machine) ==="
RESPONSE="$(curl --silent --cacert "${CERTS_DIR}/ca.crt" \
  https://server.kubernetes.local:6443/version 2>/dev/null)"
echo "${RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${RESPONSE}"
_check "API server /version endpoint" \
  curl --silent --cacert "${CERTS_DIR}/ca.crt" \
    https://server.kubernetes.local:6443/version

# ------------------------------------------------------------------------------
# TEST 3 — kubectl cluster-info
# Runs on: server/control-plane (via SSH)
#
# Runs kubectl cluster-info on the server using the admin kubeconfig. Confirms:
#   - kubectl can authenticate to the API server with the admin client cert
#   - The API server advertises its own address correctly (https://127.0.0.1:6443)
# This is the equivalent of the doc's manual verification step.
# ------------------------------------------------------------------------------
echo ""
echo "=== [3/4] kubectl cluster-info (from server) ==="
ssh "${SSH_OPTS[@]}" root@server \
  "kubectl cluster-info --kubeconfig ~/admin.kubeconfig"

# ------------------------------------------------------------------------------
# TEST 4 — RBAC ClusterRole and ClusterRoleBinding for kubelet authorization
# Runs on: server/control-plane (via SSH)
#
# Verifies that the kube-apiserver-to-kubelet.yaml manifest was applied.
# This RBAC config grants kube-apiserver the right to:
#   - Retrieve logs, metrics, and exec into pods (via the Kubelet API)
#   - Use Webhook authorization mode on worker nodes
#
# Objects expected:
#   ClusterRole        system:kube-apiserver-to-kubelet
#   ClusterRoleBinding system:kube-apiserver
# ------------------------------------------------------------------------------
echo ""
echo "=== [4/4] RBAC — ClusterRole for kubelet authorization ==="
ssh "${SSH_OPTS[@]}" root@server bash -s <<'REMOTE'
if kubectl get clusterrole system:kube-apiserver-to-kubelet \
     --kubeconfig ~/admin.kubeconfig >/dev/null 2>&1; then
  echo "  PASS: ClusterRole system:kube-apiserver-to-kubelet exists"
else
  echo "  FAIL: ClusterRole system:kube-apiserver-to-kubelet not found"
fi
if kubectl get clusterrolebinding system:kube-apiserver \
     --kubeconfig ~/admin.kubeconfig >/dev/null 2>&1; then
  echo "  PASS: ClusterRoleBinding system:kube-apiserver exists"
else
  echo "  FAIL: ClusterRoleBinding system:kube-apiserver not found"
fi
REMOTE

echo ""
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"
if [[ ${FAIL} -eq 0 ]]; then
  echo "=== Control plane verification passed ==="
  echo "Next: ./scripts/09-workers/bootstrap-workers.sh"
else
  echo "=== ${FAIL} check(s) failed — review output above ==="
  exit 1
fi
