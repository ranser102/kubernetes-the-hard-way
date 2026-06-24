#!/usr/bin/env bash

# ==============================================================================
# KTHW POD NETWORK ROUTES — Verification
# Runs on: jumpbox/local machine
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MACHINES_FILE="${ROOT_DIR}/scripts/machines.txt"
HOSTS_INTERNAL="${ROOT_DIR}/scripts/hosts.internal"
SSH_KEY="${KTHW_SSH_KEY_PATH:-${HOME}/.ssh/google_compute_engine}"

SSH_OPTS=(
  -i "${SSH_KEY}"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
)

PASS=0
FAIL=0

_check_local_cni_route() {
  local host="$1" subnet="$2"
  if ssh "${SSH_OPTS[@]}" "root@${host}" \
       "test -n \"\$(ip route show '${subnet}')\"" 2>/dev/null; then
    echo "  PASS: ${host} owns local CNI route ${subnet}"
    (( PASS++ )) || true
  else
    echo "  FAIL: ${host} missing local CNI route ${subnet}"
    (( FAIL++ )) || true
  fi
}

_check_no_stale_route() {
  local host="$1" subnet="$2"
  if ssh "${SSH_OPTS[@]}" "root@${host}" \
       "test -z \"\$(ip route show '${subnet}')\"" 2>/dev/null; then
    echo "  PASS: ${host} has no stale direct Linux route for ${subnet}"
    (( PASS++ )) || true
  else
    echo "  FAIL: ${host} still has stale direct Linux route for ${subnet}"
    (( FAIL++ )) || true
  fi
}

_check_gcp_route() {
  local name="$1" subnet="$2" instance="$3"
  local next_hop

  next_hop="$(gcloud compute routes describe "${name}" \
    --format="value(nextHopInstance)" 2>/dev/null || true)"

  if [[ "${next_hop}" == *"/${instance}" ]]; then
    echo "  PASS: GCP route ${name} sends ${subnet} to ${instance}"
    (( PASS++ )) || true
  else
    echo "  FAIL: GCP route ${name} missing or not pointing ${subnet} to ${instance}"
    (( FAIL++ )) || true
  fi
}

# Read topology
_internal_ip() { grep "[[:space:]]${1}$" "${HOSTS_INTERNAL}" | awk '{print $1}'; }
_pod_subnet()  { grep "[[:space:]]${1}[[:space:]]" "${MACHINES_FILE}" | awk '{print $4}'; }

NODE_0_IP="$(_internal_ip node-0)"
NODE_0_SUBNET="$(_pod_subnet node-0)"
NODE_1_IP="$(_internal_ip node-1)"
NODE_1_SUBNET="$(_pod_subnet node-1)"

# ------------------------------------------------------------------------------
# TEST 1 — GCP VPC route entries
# Runs on: local machine (gcloud)
#
# Checks that the VPC fabric knows which worker owns each pod CIDR. Without
# these routes, the cloud network can drop packets whose destination is a pod IP
# even when Linux routes on the nodes look correct.
# ------------------------------------------------------------------------------
echo "=== [1/3] GCP VPC pod CIDR routes ==="
_check_gcp_route kubernetes-route-10-200-0-0-24 "${NODE_0_SUBNET}" node-0
_check_gcp_route kubernetes-route-10-200-1-0-24 "${NODE_1_SUBNET}" node-1

# ------------------------------------------------------------------------------
# TEST 2 — Linux route table entries
# Runs on: server, node-0, node-1 (via SSH)
#
# Checks that workers own only their local CNI route, and no stale direct
# cross-node route remains. Remote pod CIDRs should go to the GCP VPC gateway;
# the cloud routes above deliver them to the correct next-hop instance.
# ------------------------------------------------------------------------------
echo ""
echo "=== [2/3] Linux route table entries ==="
_check_no_stale_route server "${NODE_0_SUBNET}"
_check_no_stale_route server "${NODE_1_SUBNET}"
_check_local_cni_route node-0 "${NODE_0_SUBNET}"
_check_no_stale_route node-0 "${NODE_1_SUBNET}"
_check_local_cni_route node-1 "${NODE_1_SUBNET}"
_check_no_stale_route node-1 "${NODE_0_SUBNET}"

echo ""
echo "  --- Full pod route table per node ---"
for host in server node-0 node-1; do
  echo "  ${host}:"
  ssh "${SSH_OPTS[@]}" "root@${host}" \
    "ip route show | awk '/10\\.200\\./ { found = 1; print \"    \" \$0 } END { if (!found) print \"    (no pod routes found)\" }'"
done

# ------------------------------------------------------------------------------
# TEST 3 — Cross-node VPC reachability (ping internal IP)
# Runs on: node-0 and node-1 (via SSH)
#
# Pings the other node's internal VPC IP (10.240.0.x) to confirm basic
# node-to-node connectivity across the VPC. This is a prerequisite for pod
# routing to work.
#
# Note: pod subnet gateway IPs (e.g. 10.200.0.1) do NOT exist yet — they are
# created by the CNI bridge plugin only when the first pod is scheduled on each
# node. Pod-to-pod reachability is verified in step 12 (smoke test).
# ------------------------------------------------------------------------------
echo ""
echo "=== [3/3] Cross-node VPC reachability ==="

if ssh "${SSH_OPTS[@]}" root@node-0 "ping -c 2 -W 2 ${NODE_1_IP}" >/dev/null 2>&1; then
  echo "  PASS: node-0 can reach node-1 internal IP (${NODE_1_IP})"
  (( PASS++ )) || true
else
  echo "  FAIL: node-0 cannot reach node-1 (${NODE_1_IP}) — VPC connectivity issue"
  (( FAIL++ )) || true
fi

if ssh "${SSH_OPTS[@]}" root@node-1 "ping -c 2 -W 2 ${NODE_0_IP}" >/dev/null 2>&1; then
  echo "  PASS: node-1 can reach node-0 internal IP (${NODE_0_IP})"
  (( PASS++ )) || true
else
  echo "  FAIL: node-1 cannot reach node-0 (${NODE_0_IP}) — VPC connectivity issue"
  (( FAIL++ )) || true
fi

echo ""
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"
if [[ ${FAIL} -eq 0 ]]; then
  echo "=== Pod network route verification passed ==="
  echo "Next: ./scripts/12-smoke-test/smoke-test.sh"
else
  echo "=== ${FAIL} check(s) failed — review output above ==="
  exit 1
fi
