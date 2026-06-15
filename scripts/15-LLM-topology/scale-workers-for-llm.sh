#!/usr/bin/env bash

# ==============================================================================
# KTHW — Step 15: Scale worker nodes in-place for LLM workloads
# Runs on: jumpbox/local machine (uses gcloud CLI + SSH to server for kubectl)
#
# Topology:
#   Control Plane : server  (e2-small → unchanged)
#   Workers       : node-0, node-1  (e2-small → e2-standard-4)
#
# What this script does (one node at a time, rolling):
#   1. Pre-check  — kubectl can reach the API server
#   2. Drain      — safely evict all pods from the node
#   3. Scale      — stop VM, resize to e2-standard-4, restart VM
#   4. Verify     — wait until node is Ready again
#   5. Uncordon   — restore scheduling on the node
#
# Idempotency:
#   - If a node already runs on e2-standard-4 the resize step is skipped.
#   - All gcloud/kubectl operations are guarded so re-running is safe.
#
# Attached disks (data disks, not boot) are left untouched; a machine-type
# change never detaches or modifies secondary persistent disks.
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration — override via environment variables if needed
# ------------------------------------------------------------------------------
TARGET_MACHINE_TYPE="${TARGET_MACHINE_TYPE:-e2-standard-4}"
WORKERS=("node-0" "node-1")
READY_TIMEOUT_S="${READY_TIMEOUT_S:-300}"   # seconds to wait for node Ready
POLL_INTERVAL_S="${POLL_INTERVAL_S:-5}"

SSH_KEY="${KTHW_SSH_KEY_PATH:-${HOME}/.ssh/google_compute_engine}"
SSH_OPTS=(
  -i "${SSH_KEY}"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
)

# Resolve zone from gcloud active config; allow env-override.
KTHW_ZONE="${KTHW_ZONE:-$(gcloud config get-value compute/zone 2>/dev/null)}"
if [[ -z "${KTHW_ZONE}" ]]; then
  echo "ERROR: compute/zone is not set. Run: gcloud config set compute/zone <zone>"
  exit 1
fi

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
info() { log "INFO  $*"; }
ok()   { log "OK    $*"; }
warn() { log "WARN  $*"; }
die()  { log "ERROR $*" >&2; exit 1; }

# Run kubectl on the control-plane server via SSH (matches project convention).
# Arguments are shell-quoted with printf '%q' so special characters in jsonpath
# expressions (e.g. '?(', '@', '==') survive the SSH argument-joining step and
# reach the remote bash without triggering a syntax error.
kube() {
  ssh "${SSH_OPTS[@]}" root@server \
    "kubectl --kubeconfig /root/admin.kubeconfig $(printf ' %q' "$@")"
}

# Return the current machine type for a given instance.
get_machine_type() {
  gcloud compute instances describe "$1" \
    --zone "${KTHW_ZONE}" \
    --format="value(machineType)" \
    | sed 's|.*/||'
}

# Return the scheduling status (RUNNING / TERMINATED / …).
get_instance_status() {
  gcloud compute instances describe "$1" \
    --zone "${KTHW_ZONE}" \
    --format="value(status)"
}

# Poll until kubectl reports the node as Ready.
# Distinguishes between three outcomes each iteration:
#   "True"  — node is Ready, return success
#   ""      — kubectl/SSH failed entirely (connection problem, not node state)
#   other   — node exists but condition is False/Unknown
wait_for_ready() {
  local node="$1"
  local deadline=$(( $(date +%s) + READY_TIMEOUT_S ))
  local ssh_fail_streak=0
  info "Waiting up to ${READY_TIMEOUT_S}s for ${node} to become Ready..."
  while true; do
    local raw_output
    raw_output="$(kube get node "${node}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>&1)" && rc=0 || rc=$?

    if [[ ${rc} -ne 0 ]]; then
      (( ssh_fail_streak++ )) || true
      warn "  kubectl/SSH call failed (streak=${ssh_fail_streak}): ${raw_output}"
      if (( ssh_fail_streak >= 5 )); then
        die "kubectl/SSH to 'server' failed ${ssh_fail_streak} times in a row. " \
            "Check: (1) 'server' VM is running, (2) /etc/hosts has the current external IP, " \
            "(3) SSH key is valid. Re-run configure-compute-resources-ssh.sh if the IP changed."
      fi
    else
      ssh_fail_streak=0
      local status="${raw_output}"
      if [[ "${status}" == "True" ]]; then
        ok "${node} is Ready"
        return 0
      fi
      info "  ${node} Ready=${status:-NotReady/Unknown}, retrying in ${POLL_INTERVAL_S}s..."
    fi

    if (( $(date +%s) >= deadline )); then
      die "${node} did not reach Ready within ${READY_TIMEOUT_S}s. " \
          "Check kubelet on ${node}: ssh root@${node} systemctl status kubelet"
    fi
    sleep "${POLL_INTERVAL_S}"
  done
}

# ==============================================================================
# STEP 0 — Pre-flight checks
# ==============================================================================
log "======================================================"
log "  KTHW Worker Scale-Up: e2-small → ${TARGET_MACHINE_TYPE}"
log "  Zone  : ${KTHW_ZONE}"
log "  Nodes : ${WORKERS[*]}"
log "======================================================"
echo ""

# --------------------------------------------------------------------------
# Refresh /etc/hosts and flush stale known-hosts entries.
#
# GCP ephemeral external IPs change whenever a VM is stopped and restarted.
# Running configure-compute-resources-ssh.sh re-queries gcloud for live IPs
# and rewrites the "# BEGIN Kubernetes The Hard Way" block in /etc/hosts.
# We also remove stale known_hosts entries so SSH never blocks on a changed
# host key from a freshly started VM.
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REFRESH_SCRIPT="${ROOT_DIR}/scripts/03-compute-resources/configure-compute-resources-ssh.sh"

info "[Pre-flight] Refreshing /etc/hosts with current GCP external IPs..."
if [[ -x "${REFRESH_SCRIPT}" ]]; then
  "${REFRESH_SCRIPT}"
  ok "/etc/hosts updated."
else
  warn "configure-compute-resources-ssh.sh not found at ${REFRESH_SCRIPT}. " \
       "Skipping — if external IPs changed, SSH may fail."
fi

info "[Pre-flight] Flushing stale SSH known-hosts entries for cluster nodes..."
for host in server node-0 node-1; do
  ssh-keygen -R "${host}" -f "${HOME}/.ssh/known_hosts" >/dev/null 2>&1 || true
done
ok "known_hosts flushed."

info "[Pre-flight] Verifying kubectl can reach the API server..."
if ! kube cluster-info --request-timeout=10s >/dev/null 2>&1; then
  die "kubectl cannot reach the API server on 'server'. " \
      "Ensure the server is running and admin.kubeconfig is valid."
fi
ok "API server is reachable."
echo ""

# ==============================================================================
# STEP 1 — Rolling scale: one node at a time
# ==============================================================================
for node in "${WORKERS[@]}"; do
  log "======================================================"
  log "  Processing worker: ${node}"
  log "======================================================"

  # --------------------------------------------------------------------------
  # Idempotency check: skip resize if already at target type
  # --------------------------------------------------------------------------
  current_type="$(get_machine_type "${node}")"
  info "[${node}] Current machine type: ${current_type}"

  if [[ "${current_type}" == "${TARGET_MACHINE_TYPE}" ]]; then
    warn "[${node}] Already running ${TARGET_MACHINE_TYPE}. Skipping resize."
    # Still verify the node is Ready (it may have been left cordoned from a
    # previous interrupted run) and uncordon it.
    wait_for_ready "${node}"
    info "[${node}] Ensuring node is uncordoned..."
    kube uncordon "${node}" || true
    ok "[${node}] Nothing to do — already at target size and Ready."
    echo ""
    continue
  fi

  # --------------------------------------------------------------------------
  # [1/4] Drain
  # --------------------------------------------------------------------------
  info "[${node}] [1/4] Draining node (evicting pods)..."
  # --force is needed for pods not managed by a controller (bare pods).
  # --delete-emptydir-data acknowledges that emptyDir volumes will be deleted.
  # --ignore-daemonsets skips DaemonSet pods which cannot be evicted.
  kube drain "${node}" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --timeout=120s
  ok "[${node}] Drain complete."

  # --------------------------------------------------------------------------
  # [2/4] Resize: stop → set-machine-type → start
  # --------------------------------------------------------------------------
  info "[${node}] [2/4] Stopping VM..."
  local_status="$(get_instance_status "${node}")"
  if [[ "${local_status}" != "TERMINATED" ]]; then
    gcloud compute instances stop "${node}" \
      --zone "${KTHW_ZONE}" \
      --quiet
  else
    warn "[${node}] VM is already TERMINATED, skipping stop."
  fi
  ok "[${node}] VM is stopped."

  info "[${node}] Changing machine type: ${current_type} → ${TARGET_MACHINE_TYPE}..."
  # --no-restart-required suppresses the extra reboot gcloud may otherwise trigger
  gcloud compute instances set-machine-type "${node}" \
    --zone "${KTHW_ZONE}" \
    --machine-type "${TARGET_MACHINE_TYPE}"
  ok "[${node}] Machine type updated."

  info "[${node}] Starting VM..."
  gcloud compute instances start "${node}" \
    --zone "${KTHW_ZONE}" \
    --quiet
  ok "[${node}] VM is starting."

  # --------------------------------------------------------------------------
  # [3/4] Verify: poll until node is Ready
  # --------------------------------------------------------------------------
  info "[${node}] [3/4] Waiting for kubelet to reconnect and node to become Ready..."
  # Give the OS a moment to fully boot before hammering the API.
  sleep 15
  wait_for_ready "${node}"

  # --------------------------------------------------------------------------
  # [4/4] Uncordon
  # --------------------------------------------------------------------------
  info "[${node}] [4/4] Uncordoning node..."
  kube uncordon "${node}"
  ok "[${node}] Node is uncordoned and available for scheduling."

  log "=== ${node} scaled to ${TARGET_MACHINE_TYPE} successfully ==="
  echo ""
done

# ==============================================================================
# Summary
# ==============================================================================
log "======================================================"
log "  Scale-up complete. Final node status:"
log "======================================================"
kube get nodes -o wide
echo ""
log "Workers are now ${TARGET_MACHINE_TYPE} (4 vCPUs / 16 GB RAM)."
log "You can now deploy Ollama + Open WebUI workloads."
