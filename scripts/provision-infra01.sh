#!/usr/bin/env bash

# ==============================================================================
# KTHW SCALE-DOWN: 1 CONTROLLER + 2 WORKERS PROVISIONING SCRIPT
# ==============================================================================
# Prerequisite: ./scripts/prereq01.sh (after init01.sh on a new project)
# Maps docs/01-prerequisites.md: server=controller-0, node-0/1=worker-0/1
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/prereq01.sh"

KTHW_REGION=$(gcloud config get-value compute/region)
KTHW_ZONE=$(gcloud config get-value compute/zone)

echo "=== [Phase A] Creating Dedicated VPC Network ==="
if gcloud compute networks describe kubernetes-the-hard-way >/dev/null 2>&1; then
  echo "Already exists: network kubernetes-the-hard-way"
else
  gcloud compute networks create kubernetes-the-hard-way --subnet-mode custom
fi

echo "=== [Phase A] Provisioning Regional Subnet (10.240.0.0/24) ==="
if gcloud compute networks subnets describe kubernetes \
  --region "${KTHW_REGION}" >/dev/null 2>&1; then
  echo "Already exists: subnet kubernetes in ${KTHW_REGION}"
else
  gcloud compute networks subnets create kubernetes \
    --network kubernetes-the-hard-way \
    --range 10.240.0.0/24 \
    --region "${KTHW_REGION}"
fi

echo "=== [Phase A] Creating Internal Firewall Rule ==="
if gcloud compute firewall-rules describe kubernetes-the-hard-way-allow-internal >/dev/null 2>&1; then
  echo "Already exists: firewall kubernetes-the-hard-way-allow-internal"
else
  gcloud compute firewall-rules create kubernetes-the-hard-way-allow-internal \
    --allow tcp,udp,icmp,ipip \
    --network kubernetes-the-hard-way \
    --source-ranges 10.240.0.0/24,10.200.0.0/16
fi

echo "=== [Phase A] Creating External Management Firewall Rule ==="
if gcloud compute firewall-rules describe kubernetes-the-hard-way-allow-external >/dev/null 2>&1; then
  echo "Already exists: firewall kubernetes-the-hard-way-allow-external"
else
  gcloud compute firewall-rules create kubernetes-the-hard-way-allow-external \
    --allow tcp:22,tcp:6443,icmp \
    --network kubernetes-the-hard-way \
    --source-ranges 0.0.0.0/0
fi

echo "=== [Phase A] Allocating Static Regional Public IP ==="
if gcloud compute addresses describe kubernetes-the-hard-way \
  --region "${KTHW_REGION}" >/dev/null 2>&1; then
  echo "Already exists: address kubernetes-the-hard-way in ${KTHW_REGION}"
else
  gcloud compute addresses create kubernetes-the-hard-way \
    --region "${KTHW_REGION}"
fi

echo "=== [Phase B] Provisioning 1 Control Plane Controller ==="
if gcloud compute instances describe controller-0 \
  --zone "${KTHW_ZONE}" >/dev/null 2>&1; then
  echo "Already exists: instance controller-0 in ${KTHW_ZONE}"
else
  gcloud compute instances create controller-0 \
    --boot-disk-size 20GB \
    --can-ip-forward \
    --image-family debian-12 \
    --image-project debian-cloud \
    --machine-type e2-small \
    --private-network-ip 10.240.0.10 \
    --scopes compute-rw,storage-ro,service-management,service-control,logging-write,monitoring \
    --subnet kubernetes \
    --tags kubernetes-the-hard-way,controller \
    --zone "${KTHW_ZONE}"
fi

echo "=== [Phase B] Provisioning 2 Data Plane Workers ==="
for i in 0 1; do
  if gcloud compute instances describe "worker-${i}" \
    --zone "${KTHW_ZONE}" >/dev/null 2>&1; then
    echo "Already exists: instance worker-${i} in ${KTHW_ZONE}"
  else
    gcloud compute instances create "worker-${i}" \
      --boot-disk-size 20GB \
      --can-ip-forward \
      --image-family debian-12 \
      --image-project debian-cloud \
      --machine-type e2-small \
      --metadata pod-cidr=10.200.${i}.0/24 \
      --private-network-ip 10.240.0.2${i} \
      --scopes compute-rw,storage-ro,service-management,service-control,logging-write,monitoring \
      --subnet kubernetes \
      --tags kubernetes-the-hard-way,worker \
      --zone "${KTHW_ZONE}"
  fi
done

echo "=== 1 Controller and 2 Workers are ready or already existed ==="