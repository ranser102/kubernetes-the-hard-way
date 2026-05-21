#!/usr/bin/env bash

# ==============================================================================
# KTHW COST TEARDOWN SCRIPT
# ==============================================================================
# Deletes resources from provision-infra01.sh that can incur cost, especially VMs.
# By default this also releases the static regional IP and removes KTHW networking.
#
# Usage:
#   ./scripts/teardown-infra01.sh
#
# Optional:
#   KEEP_NETWORK=true ./scripts/teardown-infra01.sh
# ==============================================================================
set -euo pipefail

KTHW_REGION=$(gcloud config get-value compute/region)
KTHW_ZONE=$(gcloud config get-value compute/zone)
KEEP_NETWORK="${KEEP_NETWORK:-true}"

delete_instance_if_exists() {
  local name="$1"

  if gcloud compute instances describe "${name}" \
    --zone "${KTHW_ZONE}" >/dev/null 2>&1; then
    echo "Deleting VM: ${name}"
    gcloud compute instances delete "${name}" \
      --zone "${KTHW_ZONE}" \
      --quiet
  else
    echo "Already absent: VM ${name}"
  fi
}

delete_firewall_if_exists() {
  local name="$1"

  if gcloud compute firewall-rules describe "${name}" >/dev/null 2>&1; then
    echo "Deleting firewall rule: ${name}"
    gcloud compute firewall-rules delete "${name}" --quiet
  else
    echo "Already absent: firewall rule ${name}"
  fi
}

echo "=== [1/5] Deleting billable compute instances ==="
delete_instance_if_exists server
delete_instance_if_exists node-0
delete_instance_if_exists node-1
delete_instance_if_exists controller-0
delete_instance_if_exists worker-0
delete_instance_if_exists worker-1

echo "=== [2/5] Releasing static regional public IP ==="
if gcloud compute addresses describe kubernetes-the-hard-way \
  --region "${KTHW_REGION}" >/dev/null 2>&1; then
  echo "Deleting address: kubernetes-the-hard-way"
  gcloud compute addresses delete kubernetes-the-hard-way \
    --region "${KTHW_REGION}" \
    --quiet
else
  echo "Already absent: address kubernetes-the-hard-way"
fi

if [[ "${KEEP_NETWORK}" == "true" ]]; then
  echo "=== KEEP_NETWORK=true; skipping firewall, subnet, and VPC deletion ==="
  echo "=== Cost teardown complete: VMs and static IP are removed ==="
  exit 0
fi

echo "=== [3/5] Deleting firewall rules ==="
delete_firewall_if_exists kubernetes-the-hard-way-allow-internal
delete_firewall_if_exists kubernetes-the-hard-way-allow-external

echo "=== [4/5] Deleting regional subnet ==="
if gcloud compute networks subnets describe kubernetes \
  --region "${KTHW_REGION}" >/dev/null 2>&1; then
  echo "Deleting subnet: kubernetes"
  gcloud compute networks subnets delete kubernetes \
    --region "${KTHW_REGION}" \
    --quiet
else
  echo "Already absent: subnet kubernetes"
fi

echo "=== [5/5] Deleting VPC network ==="
if gcloud compute networks describe kubernetes-the-hard-way >/dev/null 2>&1; then
  echo "Deleting network: kubernetes-the-hard-way"
  gcloud compute networks delete kubernetes-the-hard-way --quiet
else
  echo "Already absent: network kubernetes-the-hard-way"
fi

echo "=== Cost teardown complete ==="
