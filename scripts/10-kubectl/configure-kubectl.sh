#!/usr/bin/env bash

# ==============================================================================
# KTHW KUBECTL — Configure local kubectl for remote cluster access
# Runs on: jumpbox/local machine
#
# Writes credentials into ~/.kube/config (the default kubectl config location)
# so that kubectl commands work from the jumpbox without specifying --kubeconfig.
#
# This is different from the kubeconfigs created in step 05:
#   - Step 05 kubeconfigs are for cluster components talking to each other
#   - This kubeconfig is for the admin to access the cluster from the jumpbox
#
# The API server is reached via server.kubernetes.local:6443 (external IP,
# resolved via /etc/hosts set up in step 03).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CERTS_DIR="${ROOT_DIR}/scripts/certs"

# ------------------------------------------------------------------------------
# Pre-flight: confirm the API server is reachable before touching ~/.kube/config
# ------------------------------------------------------------------------------
echo "=== [1/3] Verifying API server is reachable ==="
if ! curl --silent --cacert "${CERTS_DIR}/ca.crt" \
     https://server.kubernetes.local:6443/version >/dev/null; then
  echo "CRITICAL: Cannot reach https://server.kubernetes.local:6443"
  echo "  Check: server is in /etc/hosts (run configure-compute-resources-ssh.sh)"
  echo "  Check: firewall allows port 6443 from your IP"
  exit 1
fi
echo "API server is reachable."

# ------------------------------------------------------------------------------
# Configure cluster, credentials, and context in ~/.kube/config
# --embed-certs on set-cluster bakes the CA into the kubeconfig so it is
# self-contained and works regardless of where CERTS_DIR is.
# Credentials use file references (not embedded) — standard for admin access.
# ------------------------------------------------------------------------------
echo ""
echo "=== [2/3] Writing admin kubeconfig to ~/.kube/config ==="
mkdir -p ~/.kube

# Register the cluster — embeds the CA cert so TLS verification is self-contained
kubectl config set-cluster kubernetes-the-hard-way \
  --certificate-authority="${CERTS_DIR}/ca.crt" \
  --embed-certs=true \
  --server=https://server.kubernetes.local:6443

# Register the admin user credentials (client cert + key for mTLS auth)
kubectl config set-credentials admin \
  --client-certificate="${CERTS_DIR}/admin.crt" \
  --client-key="${CERTS_DIR}/admin.key"

# Create a named context that ties the cluster and user together
kubectl config set-context kubernetes-the-hard-way \
  --cluster=kubernetes-the-hard-way \
  --user=admin

# Activate this context as the default
kubectl config use-context kubernetes-the-hard-way

echo "kubectl context 'kubernetes-the-hard-way' is now active."

# ------------------------------------------------------------------------------
# Quick sanity check — confirm kubectl can reach the cluster
# ------------------------------------------------------------------------------
echo ""
echo "=== [3/3] Sanity check ==="
kubectl version
echo ""
echo "=== kubectl is configured for remote cluster access ==="
echo "Next: run ./scripts/10-kubectl/verify-kubectl.sh"
