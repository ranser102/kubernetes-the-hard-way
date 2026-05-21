#!/usr/bin/env bash

# ==============================================================================
# IDEMPOTENT KTHW INITIALIZATION SCRIPT (PUBLIC REPO COMPLIANT)
# ==============================================================================
set -euo pipefail

KTHW_REGION="${KTHW_REGION:-us-east1}"
KTHW_ZONE="${KTHW_ZONE:-us-east1-b}"

echo "=== [1/5] Authenticating Local Session ==="
ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
if [[ -z "${ACTIVE_ACCOUNT}" ]]; then
  gcloud auth login
else
  echo "Already authenticated as ${ACTIVE_ACCOUNT}"
fi

echo "=== [2/5] Selecting Or Creating KTHW Project ==="
CURRENT_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"

if [[ -n "${KTHW_PROJECT_ID:-}" ]]; then
  echo "Using project from KTHW_PROJECT_ID: ${KTHW_PROJECT_ID}"
elif [[ -n "${CURRENT_PROJECT}" && "${CURRENT_PROJECT}" != "(unset)" ]] \
  && gcloud projects describe "${CURRENT_PROJECT}" >/dev/null 2>&1; then
  KTHW_PROJECT_ID="${CURRENT_PROJECT}"
  echo "Using existing active project: ${KTHW_PROJECT_ID}"
else
  KTHW_PROJECT_ID="kthw-sandbox-$(date +%s)"
  echo "Creating new sandbox project: ${KTHW_PROJECT_ID}"
  gcloud projects create "${KTHW_PROJECT_ID}" --name="KTHW Sandbox"
fi

export KTHW_PROJECT_ID
export KTHW_REGION
export KTHW_ZONE

echo "=== [3/5] Binding Active Workstation Context ==="
gcloud config set project "${KTHW_PROJECT_ID}"
gcloud config set compute/region "${KTHW_REGION}"
gcloud config set compute/zone "${KTHW_ZONE}"

echo "=== [4/5] Billing Association ==="
BILLING_ENABLED="$(gcloud billing projects describe "${KTHW_PROJECT_ID}" \
  --format='value(billingEnabled)' 2>/dev/null || echo "false")"

if [[ "${BILLING_ENABLED}" == "True" || "${BILLING_ENABLED}" == "true" ]]; then
  echo "Billing already enabled on ${KTHW_PROJECT_ID}"
else
  echo "Available Billing Accounts:"
  gcloud beta billing accounts list

  # Prompt user dynamically - inputs remain in transient memory, never written to git.
  echo ""
  read -r -p "Enter the target Billing Account ID to link: " INPUT_BILLING_ID

  if [[ -z "${INPUT_BILLING_ID}" ]]; then
    echo "CRITICAL: No Billing ID provided. Project selected but unlinked."
    exit 1
  fi

  gcloud beta billing projects link "${KTHW_PROJECT_ID}" \
    --billing-account="${INPUT_BILLING_ID}"
fi

echo "=== [5/5] Enabling Compute Engine API ==="
if gcloud services list --enabled \
  --project="${KTHW_PROJECT_ID}" \
  --filter="config.name:compute.googleapis.com" \
  --format="value(config.name)" 2>/dev/null | grep -qx "compute.googleapis.com"; then
  echo "Compute Engine API already enabled"
else
  gcloud services enable compute.googleapis.com --project="${KTHW_PROJECT_ID}"
fi

echo "=== Setup Complete. Project ${KTHW_PROJECT_ID} is ready ==="
echo "Next: ./scripts/provision-infra01.sh"