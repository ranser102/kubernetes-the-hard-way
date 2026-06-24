#!/usr/bin/env bash

# ==============================================================================
# KTHW LLMOps Infrastructure — Kubernetes bootstrap runner
# Runs on: local machine
#
# This script runs the Kubernetes provisioning steps after infrastructure exists.
# It intentionally does not deploy the LLMOps workload from module 16.
#
# Usage:
#   ./scripts/17-LLMops-infrastructure/bootstrap-k8s.sh
#
# Optional:
#   RUN_SMOKE_TEST=false ./scripts/17-LLMops-infrastructure/bootstrap-k8s.sh
#   FORCE=true ./scripts/17-LLMops-infrastructure/bootstrap-k8s.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

FORCE="${FORCE:-false}"
RUN_VERIFY="${RUN_VERIFY:-true}"
RUN_SMOKE_TEST="${RUN_SMOKE_TEST:-true}"
AUTO_CONFIRM="${AUTO_CONFIRM:-true}"
SSH_READY_TIMEOUT_S="${SSH_READY_TIMEOUT_S:-300}"
SSH_READY_POLL_INTERVAL_S="${SSH_READY_POLL_INTERVAL_S:-5}"
KTHW_ZONE="${KTHW_ZONE:-$(gcloud config get-value compute/zone 2>/dev/null)}"
GCP_INSTANCES=(server node-0 node-1)

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
info() { log "INFO  $*"; }
ok()   { log "OK    $*"; }
warn() { log "WARN  $*"; }
die()  { log "ERROR $*" >&2; exit 1; }

require_path() {
  local path="$1"
  local help="$2"

  if [[ ! -e "${path}" ]]; then
    die "Missing required path: ${path}. ${help}"
  fi
}

preflight() {
  info "Checking local bootstrap prerequisites..."
  if [[ -z "${KTHW_ZONE}" || "${KTHW_ZONE}" == "(unset)" ]]; then
    die "compute/zone is not configured. Run: gcloud config set compute/zone <zone>"
  fi

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
  ok "Local bootstrap prerequisites are present."
  echo ""
}

get_instance_external_ip() {
  gcloud compute instances describe "$1" \
    --zone "${KTHW_ZONE}" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)"
}

flush_known_host_entries() {
  local instance="$1"
  local external_ip="$2"

  ssh-keygen -R "${instance}" -f "${HOME}/.ssh/known_hosts" >/dev/null 2>&1 || true
  if [[ -n "${external_ip}" ]]; then
    ssh-keygen -R "${external_ip}" -f "${HOME}/.ssh/known_hosts" >/dev/null 2>&1 || true
  fi
}

wait_for_gcloud_ssh() {
  local instance="$1"
  local deadline=$(( $(date +%s) + SSH_READY_TIMEOUT_S ))
  local external_ip

  external_ip="$(get_instance_external_ip "${instance}")"
  flush_known_host_entries "${instance}" "${external_ip}"

  info "Waiting up to ${SSH_READY_TIMEOUT_S}s for SSH on ${instance} (${external_ip:-no external IP})..."
  while true; do
    if gcloud compute ssh "${instance}" \
        --zone "${KTHW_ZONE}" \
        --quiet \
        --command "true" >/dev/null 2>&1; then
      ok "GCP SSH is ready on ${instance}."
      return 0
    fi

    if (( $(date +%s) >= deadline )); then
      die "SSH did not become ready on ${instance}. Check VM status, firewall tcp:22, and serial console logs."
    fi

    warn "SSH is not ready on ${instance}; retrying in ${SSH_READY_POLL_INTERVAL_S}s..."
    sleep "${SSH_READY_POLL_INTERVAL_S}"
  done
}

wait_for_cluster_ssh() {
  info "Refreshing stale SSH known-host entries and waiting for fresh VMs..."
  for instance in "${GCP_INSTANCES[@]}"; do
    wait_for_gcloud_ssh "${instance}"
  done
  echo ""
}

run_step() {
  local label="$1"
  local script_path="$2"
  shift 2

  info "${label}"
  (
    cd "${ROOT_DIR}"
    "${script_path}" "$@"
  )
  ok "${label}"
  echo ""
}

run_force_step() {
  local label="$1"
  local script_path="$2"

  if [[ "${FORCE}" == "true" ]]; then
    run_step "${label}" "${script_path}" --force
  else
    run_step "${label}" "${script_path}"
  fi
}

log "======================================================"
log "  KTHW Kubernetes Bootstrap for LLMOps"
log "  Verify     : ${RUN_VERIFY}"
log "  Smoke test : ${RUN_SMOKE_TEST}"
log "  Force      : ${FORCE}"
log "======================================================"
echo ""

preflight

wait_for_cluster_ssh

run_step "[03] Configure compute resource SSH" \
  "${ROOT_DIR}/scripts/03-compute-resources/configure-compute-resources-ssh.sh"

run_step "[03] Restart SSH daemon on cluster nodes" \
  "${ROOT_DIR}/scripts/03-compute-resources/restart-sshd.sh"

run_step "[04] Generate TLS certificates" \
  "${ROOT_DIR}/scripts/04-certs/create-certs.sh"

run_step "[04] Copy TLS certificates" \
  "${ROOT_DIR}/scripts/04-certs/copy-certs.sh"

run_step "[05] Generate kubeconfig files" \
  "${ROOT_DIR}/scripts/05-kubeconfig/create-kubeconfig.sh"

run_step "[05] Copy kubeconfig files" \
  "${ROOT_DIR}/scripts/05-kubeconfig/copy-kubeconfig.sh"

info "[06] Generate and copy encryption config"
if [[ "${AUTO_CONFIRM}" == "true" ]]; then
  (
    cd "${ROOT_DIR}"
    printf 'y\n' | "${ROOT_DIR}/scripts/06-data-encrypt/create-encryption-config.sh"
  )
else
  (
    cd "${ROOT_DIR}"
    "${ROOT_DIR}/scripts/06-data-encrypt/create-encryption-config.sh"
  )
fi
ok "[06] Generate and copy encryption config"
echo ""

run_force_step "[07] Copy etcd files" \
  "${ROOT_DIR}/scripts/07-etcd/copy-etcd-files.sh"

run_force_step "[07] Bootstrap etcd" \
  "${ROOT_DIR}/scripts/07-etcd/bootstrap-etcd.sh"

run_force_step "[08] Copy control plane files" \
  "${ROOT_DIR}/scripts/08-controllers/copy-controller-files.sh"

run_force_step "[08] Bootstrap control plane" \
  "${ROOT_DIR}/scripts/08-controllers/bootstrap-controllers.sh"

if [[ "${RUN_VERIFY}" == "true" ]]; then
  run_step "[08] Verify control plane" \
    "${ROOT_DIR}/scripts/08-controllers/verify-controllers.sh"
fi

run_force_step "[09] Copy worker files" \
  "${ROOT_DIR}/scripts/09-workers/copy-worker-files.sh"

run_force_step "[09] Bootstrap workers" \
  "${ROOT_DIR}/scripts/09-workers/bootstrap-workers.sh"

if [[ "${RUN_VERIFY}" == "true" ]]; then
  run_step "[09] Verify workers" \
    "${ROOT_DIR}/scripts/09-workers/verify-workers.sh"
fi

run_step "[10] Configure kubectl" \
  "${ROOT_DIR}/scripts/10-kubectl/configure-kubectl.sh"

if [[ "${RUN_VERIFY}" == "true" ]]; then
  run_step "[10] Verify kubectl" \
    "${ROOT_DIR}/scripts/10-kubectl/verify-kubectl.sh"
fi

run_step "[11] Configure pod routes" \
  "${ROOT_DIR}/scripts/11-pod-routes/configure-pod-routes.sh"

if [[ "${RUN_VERIFY}" == "true" ]]; then
  run_step "[11] Verify pod routes" \
    "${ROOT_DIR}/scripts/11-pod-routes/verify-pod-routes.sh"
fi

if [[ "${RUN_SMOKE_TEST}" == "true" ]]; then
  run_step "[12] Run smoke test" \
    "${ROOT_DIR}/scripts/12-smoke-test/smoke-test.sh"
fi

log "======================================================"
log "  Kubernetes bootstrap complete."
log ""
log "  Next:"
log "    ./scripts/16-LLMops/deploy-llmops.sh"
log "======================================================"
