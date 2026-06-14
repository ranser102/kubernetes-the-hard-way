#!/usr/bin/env bash

# ==============================================================================
# KTHW KUBECTL — Verification
# Runs on: jumpbox/local machine
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CERTS_DIR="${ROOT_DIR}/scripts/certs"

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
# TEST 1 — Active context is set to kubernetes-the-hard-way
# Runs on: jumpbox/local machine
#
# Confirms that configure-kubectl.sh completed and the correct context is active.
# If this fails, kubectl commands will target the wrong cluster or fail entirely.
# ------------------------------------------------------------------------------
echo "=== [1/4] kubectl context ==="
CURRENT_CTX="$(kubectl config current-context 2>/dev/null || true)"
if [[ "${CURRENT_CTX}" == "kubernetes-the-hard-way" ]]; then
  echo "  PASS: active context is 'kubernetes-the-hard-way'"
  (( PASS++ )) || true
else
  echo "  FAIL: active context is '${CURRENT_CTX}' (expected 'kubernetes-the-hard-way')"
  echo "        Run ./scripts/10-kubectl/configure-kubectl.sh first"
  (( FAIL++ )) || true
fi

# ------------------------------------------------------------------------------
# TEST 2 — kubectl version (client + server)
# Runs on: jumpbox/local machine (kubectl talks to server.kubernetes.local:6443)
#
# Verifies that:
#   - The local kubectl binary works (Client Version)
#   - kubectl can authenticate and reach the API server (Server Version)
# A missing Server Version means TLS or auth is broken.
# ------------------------------------------------------------------------------
echo ""
echo "=== [2/4] kubectl version ==="
kubectl version
_check "kubectl can reach the API server" kubectl version

# ------------------------------------------------------------------------------
# TEST 3 — Nodes are registered and Ready
# Runs on: jumpbox/local machine (kubectl talks to server.kubernetes.local:6443)
#
# Lists all nodes as seen by the API server. Both node-0 and node-1 must be
# in Ready state. NotReady usually means kubelet or CNI is misconfigured.
# ------------------------------------------------------------------------------
echo ""
echo "=== [3/4] Node status ==="
kubectl get nodes -o wide
for node in node-0 node-1; do
  status="$(kubectl get node "${node}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "${status}" == "True" ]]; then
    echo "  PASS: ${node} is Ready"
    (( PASS++ )) || true
  else
    echo "  FAIL: ${node} status is '${status:-unknown}' (expected 'True')"
    (( FAIL++ )) || true
  fi
done

# ------------------------------------------------------------------------------
# TEST 4 — API server /version endpoint (TLS verified, no kubectl)
# Runs on: jumpbox/local machine (direct curl using cluster CA cert)
#
# Independent of kubectl config — confirms the API server TLS certificate is
# signed by the cluster CA and the endpoint is reachable over HTTPS from the
# jumpbox/local machine.
# ------------------------------------------------------------------------------
echo ""
echo "=== [4/4] API server /version via curl ==="
curl --silent --cacert "${CERTS_DIR}/ca.crt" \
  https://server.kubernetes.local:6443/version | python3 -m json.tool
_check "API server /version reachable" \
  curl --silent --cacert "${CERTS_DIR}/ca.crt" \
    https://server.kubernetes.local:6443/version

echo ""
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"
if [[ ${FAIL} -eq 0 ]]; then
  echo "=== kubectl verification passed ==="
  echo "Next: ./scripts/11-pod-routes/configure-pod-routes.sh"
else
  echo "=== ${FAIL} check(s) failed — review output above ==="
  exit 1
fi
