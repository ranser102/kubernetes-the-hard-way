#!/usr/bin/env bash

# ==============================================================================
# KTHW CONTROL PLANE — Copy binaries, unit files, and configs to server
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOWNLOADS_DIR="${ROOT_DIR}/kthw-downloads"
UNITS_DIR="${ROOT_DIR}/units"
CONFIGS_DIR="${ROOT_DIR}/configs"
KUBECONFIGS_DIR="${ROOT_DIR}/kubeconfigs"
CERTS_DIR="${ROOT_DIR}/certs"
SECRETS_DIR="${ROOT_DIR}/scripts/secrets"
SSH_KEY="${KTHW_SSH_KEY_PATH:-${HOME}/.ssh/google_compute_engine}"

FORCE=false
for arg in "$@"; do
  [[ "${arg}" == "--force" ]] && FORCE=true
done

SSH_OPTS=(
  -i "${SSH_KEY}"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
)

_remote_file_exists() {
  local host="$1" path="$2"
  ssh "${SSH_OPTS[@]}" "root@${host}" "test -f '${path}'" 2>/dev/null
}

_scp_if_needed() {
  local src="$1" dest_host="$2" dest_path="$3"
  local filename
  filename="$(basename "${src}")"
  if ! ${FORCE} && _remote_file_exists "${dest_host}" "${dest_path}"; then
    echo "Already exists on ${dest_host}: ${dest_path} — skipping."
  else
    scp "${SSH_OPTS[@]}" "${src}" "root@${dest_host}:${dest_path}"
    echo "Copied: ${filename} → ${dest_host}:${dest_path}"
  fi
}

echo "=== [1/3] Copying controller binaries ==="
for binary in kube-apiserver kube-controller-manager kube-scheduler; do
  _scp_if_needed "${DOWNLOADS_DIR}/controller/${binary}" "server" "~/${binary}"
done
_scp_if_needed "${DOWNLOADS_DIR}/client/kubectl" "server" "~/kubectl"

echo "=== [2/3] Copying systemd unit files and config files ==="
for unit in kube-apiserver.service kube-controller-manager.service kube-scheduler.service; do
  _scp_if_needed "${UNITS_DIR}/${unit}" "server" "~/${unit}"
done
_scp_if_needed "${CONFIGS_DIR}/kube-scheduler.yaml"          "server" "~/kube-scheduler.yaml"
_scp_if_needed "${CONFIGS_DIR}/kube-apiserver-to-kubelet.yaml" "server" "~/kube-apiserver-to-kubelet.yaml"

echo "=== [3/3] Copying certificates, kubeconfigs, and encryption config ==="
for cert in ca.crt ca.key kube-api-server.key kube-api-server.crt service-accounts.key service-accounts.crt; do
  _scp_if_needed "${CERTS_DIR}/${cert}" "server" "~/${cert}"
done
_scp_if_needed "${KUBECONFIGS_DIR}/kube-controller-manager.kubeconfig" "server" "~/kube-controller-manager.kubeconfig"
_scp_if_needed "${KUBECONFIGS_DIR}/kube-scheduler.kubeconfig"          "server" "~/kube-scheduler.kubeconfig"
_scp_if_needed "${KUBECONFIGS_DIR}/admin.kubeconfig"                   "server" "~/admin.kubeconfig"
_scp_if_needed "${SECRETS_DIR}/encryption-config.yaml"                 "server" "~/encryption-config.yaml"

echo "=== Verifying files on server ==="
ssh "${SSH_OPTS[@]}" root@server "ls -lh ~/kube-apiserver ~/kube-controller-manager ~/kube-scheduler ~/kubectl"

echo "=== Control plane files are ready on server ==="
echo "Next: run ./scripts/08-controllers/bootstrap-controllers.sh"
