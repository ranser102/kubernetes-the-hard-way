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

_check_route() {
  local host="$1" subnet="$2" via="$3"
  if ssh "${SSH_OPTS[@]}" "root@${host}" \
       "ip route show | grep -q '^${subnet}'" 2>/dev/null; then
    echo "  PASS: ${host} has route ${subnet} via ${via}"
    (( PASS++ )) || true
  else
    echo "  FAIL: ${host} missing route ${subnet} via ${via}"
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
# TEST 1 — Route table entries
# Runs on: server, node-0, node-1 (via SSH)
#
# Checks that each machine has the correct ip route entries for the pod subnets
# it does not own. A missing route means pods on that subnet are unreachable.
# ------------------------------------------------------------------------------
echo "=== [1/2] Route table entries ==="
_check_route server "${NODE_0_SUBNET}" "${NODE_0_IP}"
_check_route server "${NODE_1_SUBNET}" "${NODE_1_IP}"
_check_route node-0 "${NODE_1_SUBNET}" "${NODE_1_IP}"
_check_route node-1 "${NODE_0_SUBNET}" "${NODE_0_IP}"

echo ""
echo "  --- Full pod route table per node ---"
for host in server node-0 node-1; do
  echo "  ${host}:"
  ssh "${SSH_OPTS[@]}" "root@${host}" \
    "ip route show | grep '10\.200\.' | sed 's/^/    /'"
done

# ------------------------------------------------------------------------------
# TEST 2 — Cross-node VPC reachability (ping internal IP)
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
echo "=== [2/2] Cross-node VPC reachability ==="

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
