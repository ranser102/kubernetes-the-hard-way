#!/usr/bin/env bash

# ==============================================================================
# KTHW LLMOps Infrastructure — Full cluster deployment
# Runs on: local machine
#
# This is the master runner for a clean LLMOps-ready Kubernetes cluster:
#   1. Provision GCP infrastructure with larger worker disks
#   2. Bootstrap Kubernetes modules 03 through 12
#
# It stops before module 16. Deploy Ollama + Open WebUI separately with:
#   ./scripts/16-LLMops/deploy-llmops.sh
#
# Usage:
#   ./scripts/17-LLMops-infrastructure/deploy-all.sh
#
# Common overrides:
#   WORKER_BOOT_DISK_SIZE=150GB ./scripts/17-LLMops-infrastructure/deploy-all.sh
#   CLEAN_RUN=false RUN_SMOKE_TEST=false ./scripts/17-LLMops-infrastructure/deploy-all.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

die() {
  log "ERROR $*" >&2
  exit 1
}

require_path() {
  local path="$1"
  local help="$2"

  if [[ ! -e "${path}" ]]; then
    die "Missing required path: ${path}. ${help}"
  fi
}

preflight() {
  log "Checking local prerequisites before creating infrastructure..."
  require_path "${ROOT_DIR}/kthw-downloads/client/kubectl" \
    "Run ./scripts/02-jumpbox/install-cli-tools-macbook-m2.sh first."
  require_path "${ROOT_DIR}/kthw-downloads/client/etcdctl" \
    "Run ./scripts/02-jumpbox/install-cli-tools-macbook-m2.sh first."
  require_path "${ROOT_DIR}/kthw-downloads/controller/kube-apiserver" \
    "Run ./scripts/02-jumpbox/install-cli-tools-macbook-m2.sh first."
  require_path "${ROOT_DIR}/kthw-downloads/controller/etcd" \
    "Run ./scripts/02-jumpbox/install-cli-tools-macbook-m2.sh first."
  require_path "${ROOT_DIR}/kthw-downloads/worker/kubelet" \
    "Run ./scripts/02-jumpbox/install-cli-tools-macbook-m2.sh first."
  require_path "${ROOT_DIR}/kthw-downloads/cni-plugins" \
    "Run ./scripts/02-jumpbox/install-cli-tools-macbook-m2.sh first."
  require_path "${ROOT_DIR}/scripts/certs/ca.conf" \
    "The certificate templates must exist before generating certs."
  require_path "${ROOT_DIR}/configs/encryption-config.yaml" \
    "The encryption config template must exist."
  log "Prerequisites are present."
  echo ""
}

log "======================================================"
log "  KTHW LLMOps Full Cluster Deployment"
log "======================================================"
echo ""

preflight

"${SCRIPT_DIR}/provision-llmops-infra.sh"
"${SCRIPT_DIR}/bootstrap-k8s.sh"

log "======================================================"
log "  Cluster is ready for LLMOps workloads."
log ""
log "  Deploy module 16:"
log "    ./scripts/16-LLMops/deploy-llmops.sh"
log "======================================================"
