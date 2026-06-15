#!/usr/bin/env bash

# ==============================================================================
# KTHW LLMOps — Deploy Ollama + Open WebUI and pull models
# Runs on: local machine (kubectl must be configured)
#
# Usage:
#   ./scripts/16-LLMops/deploy-llmops.sh
#
# What this does:
#   1. Apply ollama.yaml       (idempotent — skips if already deployed)
#   2. Apply open-webui.yaml   (idempotent — skips if already deployed)
#   3. Wait for both pods to be Ready
#   4. Pull the default model into Ollama  (skips if already present)
#   5. List models installed in Ollama
#   6. Rollout-restart Open WebUI so it picks up OLLAMA_SERVICE_SERVICE_HOST
#   7. Start kubectl port-forward → http://localhost:8080
#
# Override the model via env var:
#   OLLAMA_MODEL=mistral:7b ./scripts/16-LLMops/deploy-llmops.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLLAMA_MANIFEST="${SCRIPT_DIR}/ollama.yaml"
WEBUI_MANIFEST="${SCRIPT_DIR}/open-webui.yaml"

OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2}"
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-300}"   # seconds
LOCAL_PORT="${LOCAL_PORT:-8080}"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
info() { log "INFO  $*"; }
ok()   { log "OK    $*"; }
die()  { log "ERROR $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Helper: wait until a deployment has at least 1 ready replica
# ------------------------------------------------------------------------------
wait_for_deployment() {
  local name="$1"
  local deadline=$(( $(date +%s) + POD_READY_TIMEOUT ))
  info "Waiting up to ${POD_READY_TIMEOUT}s for deployment/${name} to be Ready..."
  while true; do
    local ready
    ready="$(kubectl get deployment "${name}" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    if [[ "${ready}" == "1" ]]; then
      ok "deployment/${name} is Ready"
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      die "deployment/${name} did not become Ready within ${POD_READY_TIMEOUT}s. " \
          "Check: kubectl describe deployment/${name} && kubectl logs deploy/${name}"
    fi
    info "  ${name} readyReplicas=${ready:-0}, retrying in 5s..."
    sleep 5
  done
}

# ==============================================================================
# [1/7] Apply Ollama manifests (PV + PVC + Deployment + Service)
# ==============================================================================
log "======================================================"
log "  KTHW LLMOps — Deploy Ollama + Open WebUI"
log "  Model : ${OLLAMA_MODEL}"
log "======================================================"
echo ""

info "[1/7] Applying Ollama manifests..."
kubectl apply -f "${OLLAMA_MANIFEST}"
ok "Ollama manifests applied."

# ==============================================================================
# [2/7] Apply Open WebUI manifest (Deployment + Service)
# ==============================================================================
info "[2/7] Applying Open WebUI manifests..."
kubectl apply -f "${WEBUI_MANIFEST}"
ok "Open WebUI manifests applied."
echo ""

# ==============================================================================
# [3/7] Wait for Ollama to be Ready (image pull can take a few minutes)
# ==============================================================================
info "[3/7] Waiting for Ollama pod..."
# Large image (~1 GB) — give it extra time on first pull
POD_READY_TIMEOUT=420 wait_for_deployment "ollama"
echo ""

# ==============================================================================
# [4/7] Pull model — skip if already present
# ==============================================================================
info "[4/7] Checking if model '${OLLAMA_MODEL}' is already installed..."
# ollama list output: NAME   ID   SIZE   MODIFIED
# Strip the header, take the NAME column, match exactly (colon-tag aware).
# A bare name like "llama3.2" matches "llama3.2:latest" too.
existing="$(kubectl exec deploy/ollama -- ollama list 2>/dev/null \
  | tail -n +2 | awk '{print $1}' || true)"

model_present=false
while IFS= read -r line; do
  # Match "llama3.2" against "llama3.2:latest" or exact "llama3.2:3b"
  base="${line%%:*}"   # strip tag
  if [[ "${line}" == "${OLLAMA_MODEL}" || "${base}" == "${OLLAMA_MODEL}" ]]; then
    model_present=true
    break
  fi
done <<< "${existing}"

if [[ "${model_present}" == "true" ]]; then
  ok "Model '${OLLAMA_MODEL}' already present — skipping pull."
else
  info "Pulling model '${OLLAMA_MODEL}' (this may take several minutes)..."
  kubectl exec deploy/ollama -- ollama pull "${OLLAMA_MODEL}"
  ok "Model '${OLLAMA_MODEL}' pulled successfully."
fi
echo ""

# ==============================================================================
# [5/7] List all installed models
# ==============================================================================
info "[5/7] Models currently installed in Ollama:"
kubectl exec deploy/ollama -- ollama list
echo ""

# ==============================================================================
# [6/7] Rollout-restart Open WebUI
# Open WebUI must start AFTER ollama-service exists so Kubernetes injects
# OLLAMA_SERVICE_SERVICE_HOST into its environment.
# ==============================================================================
info "[6/7] Restarting Open WebUI to pick up Ollama service env var..."
kubectl rollout restart deployment/open-webui
kubectl rollout status deployment/open-webui --timeout="${POD_READY_TIMEOUT}s"
ok "Open WebUI is Ready."
echo ""

# ==============================================================================
# [7/7] Done — connect to Open WebUI
# ==============================================================================
log "======================================================"
log "  Stack is up."
log ""
log "  To access Open WebUI run in a separate terminal:"
log "    kubectl port-forward svc/open-webui ${LOCAL_PORT}:8080"
log "  Then open: http://localhost:${LOCAL_PORT}"
log "======================================================"
