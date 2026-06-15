#!/usr/bin/env bash

# ==============================================================================
# KTHW UPGRADE — Step 4: Upgrade worker nodes (node-0, node-1)
# Runs on: jumpbox/local machine (executes commands on workers via SSH)
#
# For this KTHW lab there are no user workloads, so drain/uncordon is not
# required. The upgrade is: stop services → replace binaries → start services.
#
# NOTE — If extending this cluster to run real workloads, add drain/uncordon:
#   kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
#   <upgrade steps>
#   kubectl uncordon <node>
#   <verify node is Ready before moving to the next>
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOWNLOADS_DIR="${ROOT_DIR}/kthw-downloads"
SSH_KEY="${KTHW_SSH_KEY_PATH:-${HOME}/.ssh/google_compute_engine}"

TARGET_VERSION="${KUBERNETES_VERSION:-v1.33.1}"

SSH_OPTS=(
  -i "${SSH_KEY}"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
)

for node in node-0 node-1; do
  echo "======================================================"
  echo "  Upgrading worker: ${node}"
  echo "======================================================"

  # ----------------------------------------------------------------------------
  # Check if node is already at the target version — skip if so
  # kubelet --version returns e.g. "Kubernetes v1.33.1"
  # ----------------------------------------------------------------------------
  CURRENT_VERSION="$(ssh "${SSH_OPTS[@]}" "root@${node}" \
    "kubelet --version 2>/dev/null | awk '{print \$2}'" 2>/dev/null || true)"
  echo "  Current kubelet: ${CURRENT_VERSION:-unknown}  Target: ${TARGET_VERSION}"

  if [[ "${CURRENT_VERSION}" == "${TARGET_VERSION}" ]]; then
    echo "  ${node} already at ${TARGET_VERSION} — skipping."
    echo ""
    continue
  fi

  # ----------------------------------------------------------------------------
  # Copy new worker binaries to the node
  # ----------------------------------------------------------------------------
  echo "--- [1/3] Copying new worker binaries to ${node} ---"
  for binary in crictl kube-proxy kubelet runc; do
    src="${DOWNLOADS_DIR}/worker/${binary}"
    echo "  Copying ${binary}..."
    scp "${SSH_OPTS[@]}" "${src}" "root@${node}:~/${binary}"
  done
  # containerd suite
  for binary in containerd containerd-shim-runc-v2 containerd-stress; do
    src="${DOWNLOADS_DIR}/worker/${binary}"
    echo "  Copying ${binary}..."
    scp "${SSH_OPTS[@]}" "${src}" "root@${node}:~/${binary}"
  done
  # kubectl for on-node debugging
  scp "${SSH_OPTS[@]}" "${DOWNLOADS_DIR}/client/kubectl" "root@${node}:~/kubectl"

  # ----------------------------------------------------------------------------
  # Stop services, replace binaries, restart
  # All three services are stopped together to minimise the window where
  # kubelet and containerd versions are mismatched.
  # ----------------------------------------------------------------------------
  echo "--- [2/3] Replacing binaries and restarting services on ${node} ---"
  ssh "${SSH_OPTS[@]}" "root@${node}" bash -s <<'REMOTE'
set -euo pipefail

echo "  Stopping worker services..."
systemctl stop kubelet kube-proxy containerd

echo "  Installing /usr/local/bin binaries..."
for bin in crictl kube-proxy kubelet runc kubectl; do
  mv -f ~/"${bin}" /usr/local/bin/
  chmod +x /usr/local/bin/"${bin}"
done

echo "  Installing /bin binaries (containerd suite)..."
for bin in containerd containerd-shim-runc-v2 containerd-stress; do
  mv -f ~/"${bin}" /bin/
  chmod +x /bin/"${bin}"
done

echo "  Starting worker services..."
systemctl start containerd
systemctl start kubelet
systemctl start kube-proxy

echo "  Waiting for services to settle..."
sleep 5

for svc in containerd kubelet kube-proxy; do
  systemctl is-active --quiet "${svc}" || {
    echo "  ERROR: ${svc} failed to start after upgrade. Journal:"
    journalctl -xeu "${svc}" --no-pager | tail -20
    exit 1
  }
  echo "  ${svc} is active"
done
REMOTE

  # ----------------------------------------------------------------------------
  # Verify node is Ready from the control plane before moving to the next node
  # ----------------------------------------------------------------------------
  echo "--- [3/3] Verifying ${node} is Ready ---"
  echo "  Waiting up to 30s for ${node} to become Ready..."
  status=""
  for i in $(seq 1 30); do
    status="$(ssh "${SSH_OPTS[@]}" root@server \
      "kubectl get node ${node} --kubeconfig ~/admin.kubeconfig \
       -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null || true)"
    if [[ "${status}" == "True" ]]; then
      echo "  ${node} is Ready"
      break
    fi
    sleep 1
  done
  if [[ "${status}" != "True" ]]; then
    echo "  ERROR: ${node} did not become Ready within 30s (status: ${status:-unknown})"
    exit 1
  fi

  echo "=== ${node} upgraded successfully ==="
  echo ""
done

echo "=== All worker nodes upgraded ==="
echo "Next: run ./scripts/14-upgrade/05-verify-upgrade.sh"
