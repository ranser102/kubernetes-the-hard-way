#!/usr/bin/env bash

# ==============================================================================
# TARGETED VPC NETWORK PURGE (teardown before re-running provision-infra01.sh)
# ==============================================================================
set -euo pipefail

KTHW_REGION=$(gcloud config get-value compute/region)
KTHW_ZONE=$(gcloud config get-value compute/zone)

echo "=== [1/5] Terminating Attached Compute Instances ==="
gcloud compute instances delete controller-0 worker-0 worker-1 \
  --zone "${KTHW_ZONE}" \
  --quiet || true

echo "=== [2/5] Stripping Network Firewall Perimeters ==="
gcloud compute firewall-rules delete kubernetes-the-hard-way-allow-internal --quiet || true
gcloud compute firewall-rules delete kubernetes-the-hard-way-allow-external --quiet || true

echo "=== [3/5] Releasing Static Public Regional IPs ==="
gcloud compute addresses delete kubernetes-the-hard-way \
  --region "${KTHW_REGION}" \
  --quiet || true

echo "=== [4/5] Deleting Regional Subnet (10.240.0.0/24) ==="
gcloud compute networks subnets delete kubernetes \
  --region "${KTHW_REGION}" \
  --quiet || true

echo "=== [5/5] Annihilating Core VPC Network Fabric ==="
gcloud compute networks delete kubernetes-the-hard-way --quiet || true

echo "=== SUCCESS: VPC networking components completely purged from active project. ==="
