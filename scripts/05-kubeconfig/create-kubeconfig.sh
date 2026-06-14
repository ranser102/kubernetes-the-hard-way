#!/usr/bin/env bash

# ==============================================================================
# KTHW KUBECONFIG GENERATION
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTS_DIR="${ROOT_DIR}/certs"
KUBECONFIG_DIR="${ROOT_DIR}/kubeconfigs"

mkdir -p "${KUBECONFIG_DIR}"

_kubeconfig_exists() {
  [[ -f "${KUBECONFIG_DIR}/${1}.kubeconfig" ]]
}

# ------------------------------------------------------------------------------
# Worker nodes (kubelet)
# ------------------------------------------------------------------------------
for host in node-0 node-1; do
  if _kubeconfig_exists "${host}"; then
    echo "Already exists: ${host}.kubeconfig — skipping."
    continue
  fi

  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority="${CERTS_DIR}/ca.crt" \
    --embed-certs=true \
    --server=https://server.kubernetes.local:6443 \
    --kubeconfig="${KUBECONFIG_DIR}/${host}.kubeconfig"

  kubectl config set-credentials system:node:${host} \
    --client-certificate="${CERTS_DIR}/${host}.crt" \
    --client-key="${CERTS_DIR}/${host}.key" \
    --embed-certs=true \
    --kubeconfig="${KUBECONFIG_DIR}/${host}.kubeconfig"

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:node:${host} \
    --kubeconfig="${KUBECONFIG_DIR}/${host}.kubeconfig"

  kubectl config use-context default \
    --kubeconfig="${KUBECONFIG_DIR}/${host}.kubeconfig"
done

# ------------------------------------------------------------------------------
# kube-proxy
# ------------------------------------------------------------------------------
if _kubeconfig_exists "kube-proxy"; then
  echo "Already exists: kube-proxy.kubeconfig — skipping."
else
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority="${CERTS_DIR}/ca.crt" \
    --embed-certs=true \
    --server=https://server.kubernetes.local:6443 \
    --kubeconfig="${KUBECONFIG_DIR}/kube-proxy.kubeconfig"

  kubectl config set-credentials system:kube-proxy \
    --client-certificate="${CERTS_DIR}/kube-proxy.crt" \
    --client-key="${CERTS_DIR}/kube-proxy.key" \
    --embed-certs=true \
    --kubeconfig="${KUBECONFIG_DIR}/kube-proxy.kubeconfig"

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-proxy \
    --kubeconfig="${KUBECONFIG_DIR}/kube-proxy.kubeconfig"

  kubectl config use-context default \
    --kubeconfig="${KUBECONFIG_DIR}/kube-proxy.kubeconfig"
fi

# ------------------------------------------------------------------------------
# kube-controller-manager
# ------------------------------------------------------------------------------
if _kubeconfig_exists "kube-controller-manager"; then
  echo "Already exists: kube-controller-manager.kubeconfig — skipping."
else
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority="${CERTS_DIR}/ca.crt" \
    --embed-certs=true \
    --server=https://server.kubernetes.local:6443 \
    --kubeconfig="${KUBECONFIG_DIR}/kube-controller-manager.kubeconfig"

  kubectl config set-credentials system:kube-controller-manager \
    --client-certificate="${CERTS_DIR}/kube-controller-manager.crt" \
    --client-key="${CERTS_DIR}/kube-controller-manager.key" \
    --embed-certs=true \
    --kubeconfig="${KUBECONFIG_DIR}/kube-controller-manager.kubeconfig"

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-controller-manager \
    --kubeconfig="${KUBECONFIG_DIR}/kube-controller-manager.kubeconfig"

  kubectl config use-context default \
    --kubeconfig="${KUBECONFIG_DIR}/kube-controller-manager.kubeconfig"
fi

# ------------------------------------------------------------------------------
# kube-scheduler
# ------------------------------------------------------------------------------
if _kubeconfig_exists "kube-scheduler"; then
  echo "Already exists: kube-scheduler.kubeconfig — skipping."
else
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority="${CERTS_DIR}/ca.crt" \
    --embed-certs=true \
    --server=https://server.kubernetes.local:6443 \
    --kubeconfig="${KUBECONFIG_DIR}/kube-scheduler.kubeconfig"

  kubectl config set-credentials system:kube-scheduler \
    --client-certificate="${CERTS_DIR}/kube-scheduler.crt" \
    --client-key="${CERTS_DIR}/kube-scheduler.key" \
    --embed-certs=true \
    --kubeconfig="${KUBECONFIG_DIR}/kube-scheduler.kubeconfig"

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-scheduler \
    --kubeconfig="${KUBECONFIG_DIR}/kube-scheduler.kubeconfig"

  kubectl config use-context default \
    --kubeconfig="${KUBECONFIG_DIR}/kube-scheduler.kubeconfig"
fi

# ------------------------------------------------------------------------------
# admin
# ------------------------------------------------------------------------------
if _kubeconfig_exists "admin"; then
  echo "Already exists: admin.kubeconfig — skipping."
else
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority="${CERTS_DIR}/ca.crt" \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig="${KUBECONFIG_DIR}/admin.kubeconfig"

  kubectl config set-credentials admin \
    --client-certificate="${CERTS_DIR}/admin.crt" \
    --client-key="${CERTS_DIR}/admin.key" \
    --embed-certs=true \
    --kubeconfig="${KUBECONFIG_DIR}/admin.kubeconfig"

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=admin \
    --kubeconfig="${KUBECONFIG_DIR}/admin.kubeconfig"

  kubectl config use-context default \
    --kubeconfig="${KUBECONFIG_DIR}/admin.kubeconfig"
fi

echo "=== Kubeconfig files generated successfully ==="
echo "=== Kubeconfig files can be found in ${KUBECONFIG_DIR} ==="
