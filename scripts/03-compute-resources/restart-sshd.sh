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
  echo "=== ${instance} ==="
  gcloud compute ssh "${instance}" \
    --zone "${KTHW_ZONE}" \
    --quiet \
    --command "sudo sh -c 'if command -v sshd >/dev/null 2>&1; then sshd -t; else /usr/sbin/sshd -t; fi' && \
      (sudo systemctl reload sshd || sudo systemctl reload ssh)"
done

echo "=== SSH daemon reload complete ==="

echo "=== Verifying root SSH with cluster hostnames ==="
for instance in "${GCP_INSTANCES[@]}"; do
  ssh -i "${SSH_KEY_PATH}" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    "root@${instance}" hostname
done

echo "=== Compute resources are reachable as server, node-0, and node-1 ==="
