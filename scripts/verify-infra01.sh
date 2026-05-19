#!/usr/bin/env bash

# ==============================================================================
#TOPOLOGY VERIFICATION CHECK
# ==============================================================================
set -euo pipefail

echo "=== [Verification] Auditing Active Sandbox Instances ==="
gcloud compute instances list \
  --filter="tags.items=kubernetes-the-hard-way" \
  --format="table(name,zone,networkInterfaces[0].networkIP:label=INTERNAL_IP,networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP,status)"