#!/usr/bin/env bash

# ==============================================================================
# KTHW CERTIFICATES GENERATION
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTS_DIR="${ROOT_DIR}/certs"

certs=(
  "admin" "node-0" "node-1"
  "kube-proxy" "kube-scheduler"
  "kube-controller-manager"
  "kube-api-server"
  "service-accounts"
)

for i in ${certs[*]}; do
  key="${CERTS_DIR}/${i}.key"
  csr="${CERTS_DIR}/${i}.csr"
  crt="${CERTS_DIR}/${i}.crt"

  if [[ -f "${key}" && -f "${crt}" ]] && \
     openssl x509 -checkend 0 -noout -in "${crt}" 2>/dev/null; then
    echo "Already exists and valid: ${i} — skipping."
    continue
  fi

  openssl genrsa -out "${key}" 4096

  openssl req -new -key "${key}" -sha256 \
    -config "${CERTS_DIR}/ca.conf" -section ${i} \
    -out "${csr}"

  openssl x509 -req -days 3653 -in "${csr}" \
    -copy_extensions copyall \
    -sha256 -CA "${CERTS_DIR}/ca.crt" \
    -CAkey "${CERTS_DIR}/ca.key" \
    -CAcreateserial \
    -out "${crt}"

done

echo "=== Certificates generated successfully ==="
echo "=== Certificates can be found in ${CERTS_DIR} ==="