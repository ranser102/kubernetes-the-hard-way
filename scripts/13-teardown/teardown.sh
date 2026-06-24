#!/usr/bin/env bash

# ==============================================================================
# KTHW TEARDOWN — Delete billable GCP resources
# Runs on: jumpbox/local machine
#
# GCP resource cost summary:
#   BILLED   — VMs (e2-small): ~$0.017/hr each  →  deleted by default
#   BILLED   — Static IP (unattached): ~$0.01/hr →  deleted by default
#   FREE     — Firewall rules           →  kept by default
#   FREE     — VPC network              →  kept by default
#   FREE     — Subnet                   →  kept by default
#
# Default behaviour (safe): deletes VMs + static IP only.
# To also delete networking, set: FULL_TEARDOWN=true
#
# Usage:
#   ./scripts/13-teardown/teardown.sh                   # VMs + static IP only
#   FULL_TEARDOWN=true ./scripts/13-teardown/teardown.sh # everything
#
# Idempotent: safe to re-run; already-absent resources are skipped.
# ==============================================================================
set -euo pipefail

KTHW_ZONE="${KTHW_ZONE:-$(gcloud config get-value compute/zone 2>/dev/null)}"
KTHW_REGION="${KTHW_REGION:-$(gcloud config get-value compute/region 2>/dev/null)}"
FULL_TEARDOWN="${FULL_TEARDOWN:-false}"

if [[ -z "${KTHW_ZONE}" || "${KTHW_ZONE}" == "(unset)" ]]; then
  echo "CRITICAL: compute/zone is not configured."
  exit 1
fi

# ------------------------------------------------------------------------------
# Helpers — all check existence before deleting (idempotent)
# ------------------------------------------------------------------------------
_delete_instance() {
  local name="$1"
  if gcloud compute instances describe "${name}" \
       --zone "${KTHW_ZONE}" >/dev/null 2>&1; then
    echo "  Deleting VM: ${name}"
    gcloud compute instances delete "${name}" \
      --zone "${KTHW_ZONE}" --quiet
  else
    echo "  Already absent: VM ${name}"
  fi
}

_delete_address() {
  local name="$1"
  if gcloud compute addresses describe "${name}" \
       --region "${KTHW_REGION}" >/dev/null 2>&1; then
    echo "  Deleting static IP: ${name}"
    gcloud compute addresses delete "${name}" \
      --region "${KTHW_REGION}" --quiet
  else
    echo "  Already absent: static IP ${name}"
  fi
}

_delete_firewall() {
  local name="$1"
  if gcloud compute firewall-rules describe "${name}" >/dev/null 2>&1; then
    echo "  Deleting firewall rule: ${name}"
    gcloud compute firewall-rules delete "${name}" --quiet
  else
    echo "  Already absent: firewall rule ${name}"
  fi
}

_delete_subnet() {
  local name="$1"
  if gcloud compute networks subnets describe "${name}" \
       --region "${KTHW_REGION}" >/dev/null 2>&1; then
    echo "  Deleting subnet: ${name}"
    gcloud compute networks subnets delete "${name}" \
      --region "${KTHW_REGION}" --quiet
  else
    echo "  Already absent: subnet ${name}"
  fi
}

_delete_network() {
  local name="$1"
  if gcloud compute networks describe "${name}" >/dev/null 2>&1; then
    echo "  Deleting VPC: ${name}"
    gcloud compute networks delete "${name}" --quiet
  else
    echo "  Already absent: VPC ${name}"
  fi
}

# ==============================================================================
# STEP 1 — Delete VMs (main cost driver)
# e2-small instances billed per second while running or stopped.
# ==============================================================================
echo "=== [1/2] Deleting compute instances (BILLED) ==="
_delete_instance server
_delete_instance node-0
_delete_instance node-1

# ==============================================================================
# STEP 2 — Release static IP (billed only when not attached to a running VM)
# Must be deleted after VMs since an attached IP cannot be released.
# ==============================================================================
echo ""
echo "=== [2/2] Releasing static regional IP (BILLED when unattached) ==="
_delete_address kubernetes-the-hard-way

echo ""
echo "=== Billable resources removed ==="
echo "  VPC network, subnet, and firewall rules are FREE — kept intact."
echo "  Re-provisioning: ./scripts/01-prereq/provision-infra01.sh"
echo ""

if [[ "${FULL_TEARDOWN}" != "true" ]]; then
  echo "  To also delete FREE networking resources run:"
  echo "    FULL_TEARDOWN=true ./scripts/13-teardown/teardown.sh"
  exit 0
fi

# ==============================================================================
# FULL_TEARDOWN=true — also remove free networking resources
# Only needed when abandoning the project entirely.
# ==============================================================================
echo "=== [+] FULL_TEARDOWN: removing firewall rules, subnet, and VPC ==="

_delete_firewall kubernetes-the-hard-way-allow-internal
_delete_firewall kubernetes-the-hard-way-allow-external
_delete_subnet   kubernetes
_delete_network  kubernetes-the-hard-way

echo ""
echo "=== Full teardown complete ==="
