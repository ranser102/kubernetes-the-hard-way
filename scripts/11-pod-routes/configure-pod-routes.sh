#!/usr/bin/env bash

# ==============================================================================
# KTHW POD NETWORK ROUTES — Add static routes so pods on different nodes can
#                            reach each other across the VPC
# Runs on: jumpbox/local machine (executes ip route commands on nodes via SSH)
#
# Problem this solves:
#   Each worker node owns a pod subnet (10.200.0.0/24, 10.200.1.0/24).
#   Without explicit routes, a pod on node-0 cannot reach a pod on node-1
#   because neither node knows where to forward that traffic.
#
# Solution:
#   Tell each node: "to reach pods on the OTHER node's subnet, forward
#   traffic to that node's internal VPC IP (10.240.0.x)".
#
#   Routes added:
#     server  : 10.200.0.0/24 → 10.240.0.20 (node-0)
#               10.200.1.0/24 → 10.240.0.21 (node-1)
#     node-0  : 10.200.1.0/24 → 10.240.0.21 (node-1)
#     node-1  : 10.200.0.0/24 → 10.240.0.20 (node-0)
#
# Note on persistence:
#   `ip route add` is in-memory only and is lost on reboot.
#   Routes are made persistent via /etc/network/interfaces.d/ (Debian 12).
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

# ------------------------------------------------------------------------------
# Read node internal IPs (10.240.0.x) and pod subnets (10.200.x.0/24)
# Internal IPs come from hosts.internal; subnets come from machines.txt
# ------------------------------------------------------------------------------
echo "=== [1/3] Reading network topology ==="

_internal_ip() {
  grep "[[:space:]]${1}$" "${HOSTS_INTERNAL}" | awk '{print $1}'
}

_pod_subnet() {
  grep "[[:space:]]${1}[[:space:]]" "${MACHINES_FILE}" | awk '{print $4}'
}

NODE_0_IP="$(_internal_ip node-0)"
NODE_0_SUBNET="$(_pod_subnet node-0)"
NODE_1_IP="$(_internal_ip node-1)"
NODE_1_SUBNET="$(_pod_subnet node-1)"

for var in NODE_0_IP NODE_0_SUBNET NODE_1_IP NODE_1_SUBNET; do
  if [[ -z "${!var}" ]]; then
    echo "CRITICAL: could not read ${var} from machines.txt / hosts.internal"
    exit 1
  fi
done

echo "  node-0: internal IP=${NODE_0_IP}  pod subnet=${NODE_0_SUBNET}"
echo "  node-1: internal IP=${NODE_1_IP}  pod subnet=${NODE_1_SUBNET}"

# Helper: add a route if it doesn't already exist, and persist it
_add_route() {
  local host="$1" subnet="$2" via="$3"
  ssh "${SSH_OPTS[@]}" "root@${host}" bash -s <<REMOTE
set -euo pipefail

# Detect the primary network interface from the default route
# (GCP Debian VMs use ens4, other distros may use eth0, ens160, etc.)
IFACE="\$(ip route show default | awk '/default/ {print \$5; exit}')"
if [[ -z "\${IFACE}" ]]; then
  echo "  ERROR: could not detect network interface"
  exit 1
fi

# Add route in-memory (idempotent: skip if already present)
# onlink + dev: GCP assigns VMs a /32 IP so the gateway is not on a directly
# connected subnet from the kernel's view. onlink + dev overrides that check
# and treats the next-hop as reachable on the named interface.
if ip route show | grep -q "^${subnet}"; then
  echo "  Route ${subnet} via ${via} already present — skipping."
else
  ip route add "${subnet}" via "${via}" dev "\${IFACE}" onlink
  echo "  Added route: ${subnet} via ${via} dev \${IFACE}"
fi

# Persist across reboots via /etc/network/interfaces.d/
PERSIST_FILE="/etc/network/interfaces.d/kthw-pod-routes.cfg"
mkdir -p /etc/network/interfaces.d/
if grep -q "${subnet}" "\${PERSIST_FILE}" 2>/dev/null; then
  echo "  Persistence entry for ${subnet} already present — skipping."
else
  printf 'up ip route add %s via %s dev %s onlink\n' "${subnet}" "${via}" "\${IFACE}" >> "\${PERSIST_FILE}"
  echo "  Persisted: ${subnet} via ${via} dev \${IFACE}"
fi
REMOTE
}

# ------------------------------------------------------------------------------
# Add routes — each machine gets routes to all OTHER nodes' pod subnets
# ------------------------------------------------------------------------------
echo ""
echo "=== [2/3] Adding pod network routes ==="

echo "  --- server ---"
_add_route server "${NODE_0_SUBNET}" "${NODE_0_IP}"
_add_route server "${NODE_1_SUBNET}" "${NODE_1_IP}"

echo "  --- node-0 ---"
# node-0 only needs a route to node-1 (it already owns NODE_0_SUBNET locally)
_add_route node-0 "${NODE_1_SUBNET}" "${NODE_1_IP}"

echo "  --- node-1 ---"
# node-1 only needs a route to node-0
_add_route node-1 "${NODE_0_SUBNET}" "${NODE_0_IP}"

echo ""
echo "=== [3/3] Route table summary ==="
for host in server node-0 node-1; do
  echo "  --- ${host} ---"
  ssh "${SSH_OPTS[@]}" "root@${host}" \
    "ip route show | grep -E '10\.200\.' || echo '  (no pod routes found)'"
done

echo ""
echo "=== Pod network routes configured ==="
echo "Next: run ./scripts/11-pod-routes/verify-pod-routes.sh"
