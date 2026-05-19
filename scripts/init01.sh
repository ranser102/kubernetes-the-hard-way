#!/usr/bin/env bash

# ==============================================================================
# HARDENED KTHW INITIALIZATION SCRIPT (PUBLIC REPO COMPLIANT)
# ==============================================================================
set -euo pipefail # Fail fast on errors or unbound variables

export KTHW_PROJECT_ID="kthw-sandbox-$(date +%s)"
export KTHW_REGION="us-east1"
export KTHW_ZONE="us-east1-b"

echo "=== [1/5] Authenticating Local Session ==="
gcloud auth login

echo "=== [2/5] Provisioning Isolated KTHW Project ==="
gcloud projects create "${KTHW_PROJECT_ID}" --name="KTHW Sandbox"

echo "=== [3/5] Binding Active Workstation Context ==="
gcloud config set project "${KTHW_PROJECT_ID}"
gcloud config set compute/region "${KTHW_REGION}"
gcloud config set compute/zone "${KTHW_ZONE}"

echo "=== [4/5] Dynamic Billing Association ==="
echo "Available Billing Accounts:"
gcloud beta billing accounts list

# Prompt user dynamically - inputs remain in transient memory, never written to git
echo ""
read -p "Enter the target Billing Account ID to link: " INPUT_BILLING_ID

if [ -z "${INPUT_BILLING_ID}" ]; then
    echo "CRITICAL: No Billing ID provided. Project created but unlinked."
    exit 1
fi

gcloud beta billing projects link "${KTHW_PROJECT_ID}" \
    --billing-account="${INPUT_BILLING_ID}"

echo "=== [5/5] Enabling Compute Engine API ==="
gcloud services enable compute.googleapis.com --project="${KTHW_PROJECT_ID}"

echo "=== Setup Complete. Project ${KTHW_PROJECT_ID} is fully isolated and active ==="
echo "Next: ./scripts/prereq01.sh  (or ./scripts/provision-infra01.sh if prereq already passed)"