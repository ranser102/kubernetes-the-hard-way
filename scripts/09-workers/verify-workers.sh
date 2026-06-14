#!/usr/bin/env bash

# ==============================================================================
# KTHW WORKER NODES — Verification
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
# TEST 1 — Worker service status
# Runs on: each worker node (node-0, node-1) via SSH
#
# Verifies that containerd, kubelet, and kube-proxy are all "active" (running)
# on each worker node. These three services must all be healthy for the node to
# register with the control plane and schedule pods.
# ------------------------------------------------------------------------------
echo "=== [1/3] Worker service status ==="
for node in node-0 node-1; do
  echo "  --- ${node} ---"
  ssh "${SSH_OPTS[@]}" "root@${node}" bash -s <<'REMOTE'
for svc in containerd kubelet kube-proxy; do
  state="$(systemctl is-active "${svc}" 2>/dev/null || true)"
  if [[ "${state}" == "active" ]]; then
    echo "    PASS: ${svc} is active"
  else
    echo "    FAIL: ${svc} is ${state}"
  fi
done
REMOTE
done

# ------------------------------------------------------------------------------
# TEST 2 — Nodes registered and Ready
# Runs on: server/control-plane (via SSH), using kubectl with admin.kubeconfig
#
# Queries the API server for the list of registered nodes. Both node-0 and
# node-1 must appear with STATUS=Ready, confirming that:
#   - kubelet successfully connected to kube-apiserver
#   - Node certificates (TLS) are valid and accepted
#   - containerd is reachable by kubelet (runtime endpoint healthy)
# A node in "NotReady" state typically means CNI or containerd is misconfigured.
# ------------------------------------------------------------------------------
echo ""
echo "=== [2/3] Nodes registered and Ready (from server/control-plane) ==="
ssh "${SSH_OPTS[@]}" root@server \
  "kubectl get nodes --kubeconfig ~/admin.kubeconfig"

for node in node-0 node-1; do
  _check "${node} is Ready" \
    ssh "${SSH_OPTS[@]}" root@server \
      "kubectl get node ${node} --kubeconfig ~/admin.kubeconfig \
       -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' \
       | grep -q True"
done

# ------------------------------------------------------------------------------
# TEST 3 — Swap disabled on each worker node
# Runs on: each worker node (node-0, node-1) via SSH
#
# Kubernetes requires swap to be off. If swap is active, kubelet will refuse
# to start (or log warnings depending on version). Verifies that `swapon --show`
# returns no output, meaning no swap partitions are active.
# ------------------------------------------------------------------------------
echo ""
echo "=== [3/3] Swap disabled on worker nodes ==="
for node in node-0 node-1; do
  swap_output="$(ssh "${SSH_OPTS[@]}" "root@${node}" "swapon --show" 2>/dev/null)"
  if [[ -z "${swap_output}" ]]; then
    echo "  PASS: swap is disabled on ${node}"
    (( PASS++ )) || true
  else
    echo "  FAIL: swap is active on ${node}:"
    echo "${swap_output}" | sed 's/^/    /'
    (( FAIL++ )) || true
  fi
done

echo ""
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"
if [[ ${FAIL} -eq 0 ]]; then
  echo "=== Worker node verification passed ==="
  echo "Next: ./scripts/10-kubectl/configure-kubectl.sh"
else
  echo "=== ${FAIL} check(s) failed — review output above ==="
  exit 1
fi
