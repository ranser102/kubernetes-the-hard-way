#!/usr/bin/env bash

# ==============================================================================
# KTHW WORKER NODES — Copy binaries, configs, and unit files to node-0 / node-1
# Runs on: jumpbox/local machine
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOWNLOADS_DIR="${ROOT_DIR}/kthw-downloads"
CONFIGS_DIR="${ROOT_DIR}/configs"
UNITS_DIR="${ROOT_DIR}/units"
MACHINES_FILE="${ROOT_DIR}/scripts/machines.txt"
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

# Returns 0 if the remote file already exists
_remote_file_exists() {
  local host="$1" path="$2"
  ssh "${SSH_OPTS[@]}" "root@${host}" "test -f '${path}'" 2>/dev/null
}

# Copy a single file; skip if destination already exists (unless --force)
_scp_if_needed() {
  local src="$1" dest_host="$2" dest_path="$3"
  local filename
  filename="$(basename "${src}")"
  if ! ${FORCE} && _remote_file_exists "${dest_host}" "${dest_path}"; then
    echo "    Already exists on ${dest_host}: ${dest_path} — skipping."
  else
    scp "${SSH_OPTS[@]}" "${src}" "root@${dest_host}:${dest_path}"
    echo "    Copied: ${filename} → ${dest_host}:${dest_path}"
  fi
}

for node in node-0 node-1; do
  echo "=== Copying files to ${node} ==="

  # ------------------------------------------------------------------
  # Read the pod CIDR subnet for this node from machines.txt
  # (field 4: e.g. 10.200.0.0/24)
  # ------------------------------------------------------------------
  SUBNET="$(grep "^[^ ]* [^ ]* ${node} " "${MACHINES_FILE}" | awk '{print $4}')"
  if [[ -z "${SUBNET}" ]]; then
    echo "CRITICAL: could not find pod subnet for ${node} in ${MACHINES_FILE}"
    exit 1
  fi
  echo "  Pod subnet for ${node}: ${SUBNET}"

  # ------------------------------------------------------------------
  # Generate node-specific CNI bridge config and kubelet config by
  # substituting the SUBNET placeholder in the template files
  # ------------------------------------------------------------------
  TMP_BRIDGE="$(mktemp)"
  TMP_KUBELET="$(mktemp)"
  trap 'rm -f "${TMP_BRIDGE}" "${TMP_KUBELET}"' EXIT

  sed "s|SUBNET|${SUBNET}|g" "${CONFIGS_DIR}/10-bridge.conf"    > "${TMP_BRIDGE}"
  sed "s|SUBNET|${SUBNET}|g" "${CONFIGS_DIR}/kubelet-config.yaml" > "${TMP_KUBELET}"

  echo "  --- [1/4] Node-specific generated configs ---"
  _scp_if_needed "${TMP_BRIDGE}"   "${node}" "~/10-bridge.conf"
  _scp_if_needed "${TMP_KUBELET}"  "${node}" "~/kubelet-config.yaml"

  echo "  --- [2/4] Worker binaries and shared configs ---"
  # Worker binaries: crictl, containerd*, runc, kubelet, kube-proxy
  for f in "${DOWNLOADS_DIR}"/worker/*; do
    _scp_if_needed "${f}" "${node}" "~/$(basename "${f}")"
  done
  # kubectl for on-node debugging
  _scp_if_needed "${DOWNLOADS_DIR}/client/kubectl" "${node}" "~/kubectl"
  # Shared config files
  _scp_if_needed "${CONFIGS_DIR}/99-loopback.conf"       "${node}" "~/99-loopback.conf"
  _scp_if_needed "${CONFIGS_DIR}/containerd-config.toml" "${node}" "~/containerd-config.toml"
  _scp_if_needed "${CONFIGS_DIR}/kube-proxy-config.yaml" "${node}" "~/kube-proxy-config.yaml"

  echo "  --- [3/4] Systemd unit files ---"
  for unit in containerd.service kubelet.service kube-proxy.service; do
    _scp_if_needed "${UNITS_DIR}/${unit}" "${node}" "~/${unit}"
  done

  echo "  --- [4/4] CNI plugins ---"
  # Ensure ~/cni-plugins/ exists on the remote node before copying into it
  ssh "${SSH_OPTS[@]}" "root@${node}" "mkdir -p ~/cni-plugins/"
  for f in "${DOWNLOADS_DIR}"/cni-plugins/*; do
    _scp_if_needed "${f}" "${node}" "~/cni-plugins/$(basename "${f}")"
  done

  echo "  === Done copying to ${node} ==="
  echo ""
done

echo "=== All worker files copied ==="
echo "Next: run ./scripts/09-workers/bootstrap-workers.sh"
