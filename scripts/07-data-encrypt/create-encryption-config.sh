#!/usr/bin/env bash

# ==============================================================================
# KTHW DATA ENCRYPTION CONFIG GENERATION
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIGS_DIR="${ROOT_DIR}/configs"
SECRETS_DIR="${ROOT_DIR}/scripts/secrets"

mkdir -p "${SECRETS_DIR}"

export ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

envsubst < "${CONFIGS_DIR}/encryption-config.yaml" \
  > "${SECRETS_DIR}/encryption-config.yaml"

read -r -p "Copy encryption-config.yaml to server? (y/N) " confirm
if [[ "${confirm}" =~ ^[Yy]$ ]]; then
  scp "${SECRETS_DIR}/encryption-config.yaml" root@server:~/
else
  echo "Skipping copy. File is available at ${SECRETS_DIR}/encryption-config.yaml"
  exit 0
fi

echo "=== Encryption config generated and copied to server successfully ==="
