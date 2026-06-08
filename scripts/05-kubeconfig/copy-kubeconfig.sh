#!/usr/bin/env bash

# ==============================================================================
# KTHW KUBECONFIG COPY
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_DIR="${ROOT_DIR}/kubeconfigs"

# Copy kubelet and kube-proxy kubeconfigs to worker nodes
for host in node-0 node-1; do
  ssh root@${host} "mkdir -p /var/lib/{kube-proxy,kubelet}"

  scp "${KUBECONFIG_DIR}/kube-proxy.kubeconfig" \
    root@${host}:/var/lib/kube-proxy/kubeconfig

  scp "${KUBECONFIG_DIR}/${host}.kubeconfig" \
    root@${host}:/var/lib/kubelet/kubeconfig
done

# Copy kube-controller-manager, kube-scheduler, and admin kubeconfigs to server
scp \
  "${KUBECONFIG_DIR}/admin.kubeconfig" \
  "${KUBECONFIG_DIR}/kube-controller-manager.kubeconfig" \
  "${KUBECONFIG_DIR}/kube-scheduler.kubeconfig" \
  root@server:~/

echo "=== Kubeconfig files copied successfully ==="
