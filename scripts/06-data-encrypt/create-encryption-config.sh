#!/usr/bin/env bash

# ==============================================================================
# KTHW DATA ENCRYPTION CONFIG GENERATION
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIGS_DIR="${ROOT_DIR}/configs"
SECRETS_DIR="${ROOT_DIR}/scripts/secrets"
ENCRYPTION_CONFIG="${SECRETS_DIR}/encryption-config.yaml"
SSH_KEY="${KTHW_SSH_KEY_PATH:-${HOME}/.ssh/google_compute_engine}"

SSH_OPTS=(
  -i "${SSH_KEY}"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
)

mkdir -p "${SECRETS_DIR}"

if [[ -f "${ENCRYPTION_CONFIG}" ]]; then
  echo "Already exists: ${ENCRYPTION_CONFIG} — skipping key generation."
  echo "WARNING: Re-generating the encryption key after deployment breaks all encrypted data at rest."
else
  export ENCRYPTION_KEY
  ENCRYPTION_KEY="$(head -c 32 /dev/urandom | base64)"
  envsubst < "${CONFIGS_DIR}/encryption-config.yaml" > "${ENCRYPTION_CONFIG}"
  echo "=== Encryption config written to ${ENCRYPTION_CONFIG} ==="
fi

read -r -p "Copy encryption-config.yaml to server? (y/N) " confirm
if [[ "${confirm}" =~ ^[Yy]$ ]]; then
  scp "${SSH_OPTS[@]}" "${ENCRYPTION_CONFIG}" root@server:~/
else
  echo "Skipping copy. File is available at ${ENCRYPTION_CONFIG}"
  exit 0
fi

echo "=== Encryption config generated and copied to server successfully ==="
