#!/usr/bin/env bash

# ==============================================================================
# KTHW SMOKE TEST — Cleanup
# Runs on: jumpbox/local machine
#
# Removes the resources created by smoke-test.sh.
# Run this after the upgrade simulation (step 14) when you no longer need
# the test workload, or before re-running the smoke test from scratch.
# ==============================================================================
set -euo pipefail

echo "=== Cleaning up smoke test resources ==="

# Delete the nginx NodePort service
if kubectl get svc nginx >/dev/null 2>&1; then
  kubectl delete svc nginx
  echo "  Deleted: service/nginx"
else
  echo "  Not found: service/nginx — skipping"
fi

# Delete the nginx deployment (also removes its pods)
if kubectl get deployment nginx >/dev/null 2>&1; then
  kubectl delete deployment nginx
  echo "  Deleted: deployment/nginx"
else
  echo "  Not found: deployment/nginx — skipping"
fi

# Delete the test secret
if kubectl get secret kubernetes-the-hard-way >/dev/null 2>&1; then
  kubectl delete secret kubernetes-the-hard-way
  echo "  Deleted: secret/kubernetes-the-hard-way"
else
  echo "  Not found: secret/kubernetes-the-hard-way — skipping"
fi

echo ""
echo "=== Smoke test resources removed ==="
echo "  Run ./scripts/12-smoke-test/smoke-test.sh to test again from scratch"
