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
  openssl genrsa -out "${CERTS_DIR}/${i}.key" 4096

  openssl req -new -key "${CERTS_DIR}/${i}.key" -sha256 \
    -config "${CERTS_DIR}/ca.conf" -section ${i} \
    -out "${CERTS_DIR}/${i}.csr"

  openssl x509 -req -days 3653 -in "${CERTS_DIR}/${i}.csr" \
    -copy_extensions copyall \
    -sha256 -CA "${CERTS_DIR}/ca.crt" \
    -CAkey "${CERTS_DIR}/ca.key" \
    -CAcreateserial \
    -out "${CERTS_DIR}/${i}.crt"

done

echo "=== Certificates generated successfully ==="
echo "=== Certificates can be found in ${CERTS_DIR} ==="