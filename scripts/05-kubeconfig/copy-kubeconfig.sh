#!/usr/bin/env bash

# ==============================================================================
# KTHW KUBECONFIG COPY
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_DIR="${ROOT_DIR}/kubeconfigs"
SSH_KEY="${KTHW_SSH_KEY_PATH:-${HOME}/.ssh/google_compute_engine}"

SSH_OPTS=(
  -i "${SSH_KEY}"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
)

# Returns 0 if the remote file already exists, 1 otherwise
_remote_file_exists() {
  local host="$1" path="$2"
  ssh "${SSH_OPTS[@]}" "root@${host}" "test -f '${path}'" 2>/dev/null
}

# Copy kubelet and kube-proxy kubeconfigs to worker nodes
for host in node-0 node-1; do
  ssh "${SSH_OPTS[@]}" root@${host} "mkdir -p /var/lib/{kube-proxy,kubelet}"

  if _remote_file_exists "${host}" "/var/lib/kube-proxy/kubeconfig"; then
    echo "Already exists on ${host}: /var/lib/kube-proxy/kubeconfig — skipping."
  else
    scp "${SSH_OPTS[@]}" \
      "${KUBECONFIG_DIR}/kube-proxy.kubeconfig" \
      root@${host}:/var/lib/kube-proxy/kubeconfig
  fi

  if _remote_file_exists "${host}" "/var/lib/kubelet/kubeconfig"; then
    echo "Already exists on ${host}: /var/lib/kubelet/kubeconfig — skipping."
  else
    scp "${SSH_OPTS[@]}" \
      "${KUBECONFIG_DIR}/${host}.kubeconfig" \
      root@${host}:/var/lib/kubelet/kubeconfig
  fi
done

# Copy kube-controller-manager, kube-scheduler, and admin kubeconfigs to server
for file in admin kube-controller-manager kube-scheduler; do
  if _remote_file_exists "server" "~/${file}.kubeconfig"; then
    echo "Already exists on server: ~/${file}.kubeconfig — skipping."
  else
    scp "${SSH_OPTS[@]}" \
      "${KUBECONFIG_DIR}/${file}.kubeconfig" \
      root@server:~/
  fi
done

echo "=== Kubeconfig files copied successfully ==="
