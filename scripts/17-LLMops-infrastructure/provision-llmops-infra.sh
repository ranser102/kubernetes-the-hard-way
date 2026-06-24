#!/usr/bin/env bash

# ==============================================================================
# KTHW LLMOps Infrastructure — Clean provision
# Runs on: local machine with gcloud configured
#
# This is an LLMOps-ready replacement for scripts/01-prereq/provision-infra01.sh.
# It provisions the same KTHW topology, but creates workers large enough for
# Ollama + Open WebUI from the start:
#
#   Control Plane : server  -> e2-small,      20GB boot disk
#   Workers       : node-*  -> e2-standard-4, 100GB boot disk
#
# AWS note: if you are thinking in EBS terms, WORKER_BOOT_DISK_SIZE is the GCP
# boot persistent disk size for the worker nodes.
#
# Default behavior is a clean run: delete existing server/node-0/node-1 and
# recreate them with the requested sizes. Network, subnet, and firewall rules are
# reused if present. Set CLEAN_RUN=false to skip existing VMs instead.
#
# Usage:
#   ./scripts/17-LLMops-infrastructure/provision-llmops-infra.sh
#
# Overrides:
#   WORKER_BOOT_DISK_SIZE=150GB ./scripts/17-LLMops-infrastructure/provision-llmops-infra.sh
#   CLEAN_RUN=false WORKER_MACHINE_TYPE=e2-standard-8 ./scripts/17-LLMops-infrastructure/provision-llmops-infra.sh
# ==============================================================================
set -euo pipefail

NETWORK_NAME="${NETWORK_NAME:-kubernetes-the-hard-way}"
SUBNET_NAME="${SUBNET_NAME:-kubernetes}"
ADDRESS_NAME="${ADDRESS_NAME:-kubernetes-the-hard-way}"

POD_CIDR_BASE="${POD_CIDR_BASE:-10.200}"
SUBNET_RANGE="${SUBNET_RANGE:-10.240.0.0/24}"
INTERNAL_SOURCE_RANGES="${INTERNAL_SOURCE_RANGES:-10.240.0.0/24,10.200.0.0/16}"

CONTROL_PLANE_MACHINE_TYPE="${CONTROL_PLANE_MACHINE_TYPE:-e2-small}"
CONTROL_PLANE_BOOT_DISK_SIZE="${CONTROL_PLANE_BOOT_DISK_SIZE:-20GB}"
WORKER_MACHINE_TYPE="${WORKER_MACHINE_TYPE:-e2-standard-4}"
WORKER_BOOT_DISK_SIZE="${WORKER_BOOT_DISK_SIZE:-100GB}"
WORKER_COUNT="${WORKER_COUNT:-2}"

CLEAN_RUN="${CLEAN_RUN:-true}"
DELETE_STATIC_IP_ON_CLEAN="${DELETE_STATIC_IP_ON_CLEAN:-true}"

KTHW_REGION="${KTHW_REGION:-$(gcloud config get-value compute/region 2>/dev/null)}"
KTHW_ZONE="${KTHW_ZONE:-$(gcloud config get-value compute/zone 2>/dev/null)}"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
info() { log "INFO  $*"; }
ok()   { log "OK    $*"; }
warn() { log "WARN  $*"; }
die()  { log "ERROR $*" >&2; exit 1; }

require_gcloud_config() {
  if [[ -z "${KTHW_REGION}" || "${KTHW_REGION}" == "(unset)" ]]; then
    die "compute/region is not configured. Run: gcloud config set compute/region <region>"
  fi

  if [[ -z "${KTHW_ZONE}" || "${KTHW_ZONE}" == "(unset)" ]]; then
    die "compute/zone is not configured. Run: gcloud config set compute/zone <zone>"
  fi
}

instance_exists() {
  gcloud compute instances describe "$1" --zone "${KTHW_ZONE}" >/dev/null 2>&1
}

delete_instance_if_present() {
  local name="$1"

  if instance_exists "${name}"; then
    info "Deleting existing VM ${name} for clean LLMOps reprovision..."
    gcloud compute instances delete "${name}" --zone "${KTHW_ZONE}" --quiet
  else
    info "VM ${name} is already absent."
  fi
}

delete_address_if_present() {
  if gcloud compute addresses describe "${ADDRESS_NAME}" --region "${KTHW_REGION}" >/dev/null 2>&1; then
    info "Deleting existing static IP ${ADDRESS_NAME} for clean LLMOps reprovision..."
    gcloud compute addresses delete "${ADDRESS_NAME}" --region "${KTHW_REGION}" --quiet
  else
    info "Static IP ${ADDRESS_NAME} is already absent."
  fi
}

ensure_network() {
  info "Ensuring VPC network ${NETWORK_NAME} exists..."
  if gcloud compute networks describe "${NETWORK_NAME}" >/dev/null 2>&1; then
    ok "Network ${NETWORK_NAME} already exists."
  else
    gcloud compute networks create "${NETWORK_NAME}" --subnet-mode custom
    ok "Network ${NETWORK_NAME} created."
  fi
}

ensure_subnet() {
  info "Ensuring subnet ${SUBNET_NAME} exists in ${KTHW_REGION}..."
  if gcloud compute networks subnets describe "${SUBNET_NAME}" --region "${KTHW_REGION}" >/dev/null 2>&1; then
    ok "Subnet ${SUBNET_NAME} already exists."
  else
    gcloud compute networks subnets create "${SUBNET_NAME}" \
      --network "${NETWORK_NAME}" \
      --range "${SUBNET_RANGE}" \
      --region "${KTHW_REGION}"
    ok "Subnet ${SUBNET_NAME} created."
  fi
}

ensure_firewall_rules() {
  info "Ensuring internal cluster firewall rule exists..."
  if gcloud compute firewall-rules describe "${NETWORK_NAME}-allow-internal" >/dev/null 2>&1; then
    ok "Firewall ${NETWORK_NAME}-allow-internal already exists."
  else
    gcloud compute firewall-rules create "${NETWORK_NAME}-allow-internal" \
      --allow tcp,udp,icmp,ipip \
      --network "${NETWORK_NAME}" \
      --source-ranges "${INTERNAL_SOURCE_RANGES}"
    ok "Firewall ${NETWORK_NAME}-allow-internal created."
  fi

  info "Ensuring external management firewall rule exists..."
  if gcloud compute firewall-rules describe "${NETWORK_NAME}-allow-external" >/dev/null 2>&1; then
    ok "Firewall ${NETWORK_NAME}-allow-external already exists."
  else
    gcloud compute firewall-rules create "${NETWORK_NAME}-allow-external" \
      --allow tcp:22,tcp:6443,icmp \
      --network "${NETWORK_NAME}" \
      --source-ranges 0.0.0.0/0
    ok "Firewall ${NETWORK_NAME}-allow-external created."
  fi
}

ensure_static_ip() {
  info "Ensuring static regional IP ${ADDRESS_NAME} exists..."
  if gcloud compute addresses describe "${ADDRESS_NAME}" --region "${KTHW_REGION}" >/dev/null 2>&1; then
    ok "Address ${ADDRESS_NAME} already exists."
  else
    gcloud compute addresses create "${ADDRESS_NAME}" --region "${KTHW_REGION}"
    ok "Address ${ADDRESS_NAME} created."
  fi
}

create_server() {
  if instance_exists server; then
    warn "server already exists; skipping because CLEAN_RUN=false."
    return
  fi

  info "Creating control plane server (${CONTROL_PLANE_MACHINE_TYPE}, ${CONTROL_PLANE_BOOT_DISK_SIZE})..."
  gcloud compute instances create server \
    --boot-disk-size "${CONTROL_PLANE_BOOT_DISK_SIZE}" \
    --can-ip-forward \
    --image-family debian-12 \
    --image-project debian-cloud \
    --machine-type "${CONTROL_PLANE_MACHINE_TYPE}" \
    --private-network-ip 10.240.0.10 \
    --scopes compute-rw,storage-ro,service-management,service-control,logging-write,monitoring \
    --subnet "${SUBNET_NAME}" \
    --tags kubernetes-the-hard-way,controller \
    --zone "${KTHW_ZONE}"
  ok "server created."
}

create_worker() {
  local index="$1"
  local name="node-${index}"
  local private_ip="10.240.0.2${index}"
  local pod_cidr="${POD_CIDR_BASE}.${index}.0/24"

  if instance_exists "${name}"; then
    warn "${name} already exists; skipping because CLEAN_RUN=false."
    return
  fi

  info "Creating ${name} (${WORKER_MACHINE_TYPE}, ${WORKER_BOOT_DISK_SIZE}, pod-cidr=${pod_cidr})..."
  gcloud compute instances create "${name}" \
    --boot-disk-size "${WORKER_BOOT_DISK_SIZE}" \
    --can-ip-forward \
    --image-family debian-12 \
    --image-project debian-cloud \
    --machine-type "${WORKER_MACHINE_TYPE}" \
    --metadata "pod-cidr=${pod_cidr}" \
    --private-network-ip "${private_ip}" \
    --scopes compute-rw,storage-ro,service-management,service-control,logging-write,monitoring \
    --subnet "${SUBNET_NAME}" \
    --tags kubernetes-the-hard-way,worker \
    --zone "${KTHW_ZONE}"
  ok "${name} created."
}

log "======================================================"
log "  KTHW LLMOps Infrastructure Clean Run"
log "  Region       : ${KTHW_REGION:-unset}"
log "  Zone         : ${KTHW_ZONE:-unset}"
log "  Clean run    : ${CLEAN_RUN}"
log "  Server       : ${CONTROL_PLANE_MACHINE_TYPE}, ${CONTROL_PLANE_BOOT_DISK_SIZE}"
log "  Workers      : ${WORKER_COUNT} x ${WORKER_MACHINE_TYPE}, ${WORKER_BOOT_DISK_SIZE}"
log "======================================================"
echo ""

require_gcloud_config

if [[ "${CLEAN_RUN}" == "true" ]]; then
  info "Cleaning existing cluster VMs before provisioning..."
  delete_instance_if_present server
  for ((i = 0; i < WORKER_COUNT; i++)); do
    delete_instance_if_present "node-${i}"
  done

  if [[ "${DELETE_STATIC_IP_ON_CLEAN}" == "true" ]]; then
    delete_address_if_present
  fi
  echo ""
else
  warn "CLEAN_RUN=false: existing VMs will be left unchanged."
  echo ""
fi

ensure_network
ensure_subnet
ensure_firewall_rules
ensure_static_ip
echo ""

create_server
for ((i = 0; i < WORKER_COUNT; i++)); do
  create_worker "${i}"
done

echo ""
log "======================================================"
log "  LLMOps infrastructure is ready."
log ""
log "  Next:"
log "    ./scripts/03-compute-resources/configure-compute-resources-ssh.sh"
log "    Continue the normal KTHW bootstrap steps through module 12"
log "    ./scripts/16-LLMops/deploy-llmops.sh"
log "======================================================"
