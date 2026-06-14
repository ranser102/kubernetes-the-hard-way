#!/usr/bin/env bash

# ==============================================================================
# KTHW SSH DAEMON RELOAD
# ==============================================================================
set -euo pipefail

KTHW_ZONE="${KTHW_ZONE:-$(gcloud config get-value compute/zone 2>/dev/null)}"
SSH_KEY_PATH="${KTHW_SSH_KEY_PATH:-${HOME}/.ssh/google_compute_engine}"
GCP_INSTANCES=(server node-0 node-1)

if [[ -z "${KTHW_ZONE}" || "${KTHW_ZONE}" == "(unset)" ]]; then
  echo "CRITICAL: compute/zone is not configured. Run scripts/01-prereq/init01.sh first."
  exit 1
fi

echo "=== Validating and reloading SSH daemon on compute resources ==="
for instance in "${GCP_INSTANCES[@]}"; do
  echo "--- ${instance}: validating sshd config and reloading ---"
  gcloud compute ssh "${instance}" \
    --zone "${KTHW_ZONE}" \
    --quiet \
    --command "sudo sh -c 'if command -v sshd >/dev/null 2>&1; then sshd -t; else /usr/sbin/sshd -t; fi' && \
      (sudo systemctl reload sshd || sudo systemctl reload ssh)"
done

echo "=== SSH daemon reload complete — waiting for sshd to be ready ==="
sleep 3

echo "=== Verifying root SSH with cluster hostnames ==="
FAILED=()
for instance in "${GCP_INSTANCES[@]}"; do
  # getent is Linux-only; on macOS use dns/hosts resolution via ping -c1
  if ! { getent hosts "${instance}" 2>/dev/null || \
         ping -c 1 -W 1 "${instance}" >/dev/null 2>&1; }; then
    echo "WARNING: ${instance} does not resolve — run configure-compute-resources-ssh.sh first"
    FAILED+=("${instance}")
    continue
  fi
  echo -n "  root@${instance} ... "
  ssh-keygen -R "${instance}" -f "${HOME}/.ssh/known_hosts" >/dev/null 2>&1 || true
  if ssh -i "${SSH_KEY_PATH}" \
       -o BatchMode=yes \
       -o StrictHostKeyChecking=accept-new \
       -o ConnectTimeout=15 \
       "root@${instance}" hostname 2>/dev/null; then
    :
  else
    echo "FAILED (exit $?)"
    FAILED+=("${instance}")
  fi
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "CRITICAL: root SSH failed for: ${FAILED[*]}"
  echo "  Check: PermitRootLogin yes in /etc/ssh/sshd_config on each node"
  echo "  Check: ~/.ssh/google_compute_engine.pub is in /root/.ssh/authorized_keys"
  echo "  Check: /etc/hosts has entries for ${FAILED[*]} (run configure-compute-resources-ssh.sh)"
  exit 1
fi

echo "=== Compute resources are reachable as server, node-0, and node-1 ==="
