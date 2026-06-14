#!/usr/bin/env bash

# ==============================================================================
# KTHW CERTIFICATES COPY
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTS_DIR="${ROOT_DIR}/certs"
SSH_KEY="${KTHW_SSH_KEY_PATH:-${HOME}/.ssh/google_compute_engine}"

SSH_OPTS=(
  -i "${SSH_KEY}"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
)

for host in node-0 node-1; do
  ssh "${SSH_OPTS[@]}" root@${host} mkdir -p /var/lib/kubelet/

  scp "${SSH_OPTS[@]}" \
    "${CERTS_DIR}/ca.crt" \
    root@${host}:/var/lib/kubelet/

  scp "${SSH_OPTS[@]}" \
    "${CERTS_DIR}/${host}.crt" \
    root@${host}:/var/lib/kubelet/kubelet.crt

  scp "${SSH_OPTS[@]}" \
    "${CERTS_DIR}/${host}.key" \
    root@${host}:/var/lib/kubelet/kubelet.key
done

scp "${SSH_OPTS[@]}" \
  "${CERTS_DIR}/ca.key" \
  "${CERTS_DIR}/ca.crt" \
  "${CERTS_DIR}/kube-api-server.key" \
  "${CERTS_DIR}/kube-api-server.crt" \
  "${CERTS_DIR}/service-accounts.key" \
  "${CERTS_DIR}/service-accounts.crt" \
  root@server:~/

echo "=== Certificates copied successfully ==="
