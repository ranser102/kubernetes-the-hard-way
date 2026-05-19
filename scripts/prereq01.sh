#!/usr/bin/env bash

# ==============================================================================
# KTHW GCP PREREQUISITES (docs/01-prerequisites.md + jumpbox on workstation)
# ==============================================================================
# Satisfies lab 01 on GCP by validating the local jumpbox and GCP project, then
# enabling APIs required before provision-infra01.sh.
#
# Run order:
#   ./scripts/init01.sh           # once: new project, billing, region/zone
#   ./scripts/prereq01.sh         # before provision: checks + API enablement
#   ./scripts/provision-infra01.sh
#   ./scripts/verify-infra01.sh
# ==============================================================================
set -euo pipefail

REQUIRED_APIS=(
  compute.googleapis.com
)

echo "=== [1/5] Local jumpbox (administration host) ==="
echo "Per docs/01-prerequisites.md and docs/02-jumpbox.md, the jumpbox may be this"
echo "workstation (macOS or Linux). Cluster nodes are created by provision-infra01.sh."
echo ""

MISSING_LOCAL=()
for cmd in gcloud git curl openssl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    MISSING_LOCAL+=("${cmd}")
  fi
done

if ((${#MISSING_LOCAL[@]} > 0)); then
  echo "CRITICAL: Install missing jumpbox tools: ${MISSING_LOCAL[*]}"
  echo "  gcloud: https://cloud.google.com/sdk/docs/install"
  exit 1
fi
echo "Local tools OK: gcloud, git, curl, openssl"

echo ""
echo "=== [2/5] gcloud authentication ==="
ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
if [[ -z "${ACTIVE_ACCOUNT}" ]]; then
  echo "CRITICAL: No active gcloud account. Run: gcloud auth login"
  exit 1
fi
echo "Active account: ${ACTIVE_ACCOUNT}"

echo ""
echo "=== [3/5] GCP project, region, and zone ==="
KTHW_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
KTHW_REGION="$(gcloud config get-value compute/region 2>/dev/null || true)"
KTHW_ZONE="$(gcloud config get-value compute/zone 2>/dev/null || true)"

if [[ -z "${KTHW_PROJECT}" || "${KTHW_PROJECT}" == "(unset)" ]]; then
  echo "CRITICAL: No GCP project set. Run ./scripts/init01.sh or:"
  echo "  gcloud config set project YOUR_PROJECT_ID"
  exit 1
fi
if [[ -z "${KTHW_REGION}" || "${KTHW_REGION}" == "(unset)" ]]; then
  echo "CRITICAL: compute/region is not set. Example:"
  echo "  gcloud config set compute/region us-east1"
  exit 1
fi
if [[ -z "${KTHW_ZONE}" || "${KTHW_ZONE}" == "(unset)" ]]; then
  echo "CRITICAL: compute/zone is not set. Example:"
  echo "  gcloud config set compute/zone us-east1-b"
  exit 1
fi

if ! gcloud projects describe "${KTHW_PROJECT}" >/dev/null 2>&1; then
  echo "CRITICAL: Project '${KTHW_PROJECT}' is not accessible."
  exit 1
fi

echo "Project: ${KTHW_PROJECT}"
echo "Region:  ${KTHW_REGION}"
echo "Zone:    ${KTHW_ZONE}"

echo ""
echo "=== [4/5] Billing ==="
BILLING_ENABLED="$(gcloud billing projects describe "${KTHW_PROJECT}" \
  --format='value(billingEnabled)' 2>/dev/null || echo "false")"
if [[ "${BILLING_ENABLED}" != "True" && "${BILLING_ENABLED}" != "true" ]]; then
  echo "CRITICAL: Billing is not enabled on ${KTHW_PROJECT}."
  echo "Run ./scripts/init01.sh or link billing manually."
  exit 1
fi
echo "Billing enabled on ${KTHW_PROJECT}"

echo ""
echo "=== [5/5] Required Google Cloud APIs ==="
for api in "${REQUIRED_APIS[@]}"; do
  if ! gcloud services list --enabled \
    --project="${KTHW_PROJECT}" \
    --filter="config.name:${api}" \
    --format="value(config.name)" 2>/dev/null | grep -qx "${api}"; then
    echo "Enabling ${api}..."
    gcloud services enable "${api}" --project="${KTHW_PROJECT}"
  else
    echo "Already enabled: ${api}"
  fi
done

echo ""
echo "=== Prerequisites complete ==="
echo "Lab 01 machine mapping for this GCP sandbox:"
echo "  jumpbox  -> this workstation (${ACTIVE_ACCOUNT})"
echo "  server   -> controller-0  (10.240.0.10, Debian 12, 20GB)"
echo "  node-0   -> worker-0      (10.240.0.20, pod 10.200.0.0/24)"
echo "  node-1   -> worker-1      (10.240.0.21, pod 10.200.1.0/24)"
echo ""
echo "Next: ./scripts/provision-infra01.sh"
