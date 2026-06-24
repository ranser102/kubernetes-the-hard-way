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
#   Tell the GCP VPC fabric which worker owns each pod CIDR.
#
#   GCP routes added:
#     10.200.0.0/24 → next-hop-instance node-0
#     10.200.1.0/24 → next-hop-instance node-1
#
# Note on persistence:
#   GCP routes are persistent cloud resources.
#   Do NOT add direct Linux routes via the other worker's 10.240.0.x address.
#   Nodes should send remote pod CIDRs to the GCP VPC gateway (10.240.0.1), and
#   the cloud route then delivers the packet to the right next-hop instance.
#   Sysctl forwarding settings are persisted in /etc/sysctl.d/kubernetes.conf.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MACHINES_FILE="${ROOT_DIR}/scripts/machines.txt"
HOSTS_INTERNAL="${ROOT_DIR}/scripts/hosts.internal"
SSH_KEY="${KTHW_SSH_KEY_PATH:-${HOME}/.ssh/google_compute_engine}"
KTHW_ZONE="${KTHW_ZONE:-$(gcloud config get-value compute/zone 2>/dev/null)}"
NETWORK_NAME="${NETWORK_NAME:-kubernetes-the-hard-way}"

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
echo "=== [1/4] Reading network topology ==="

if [[ -z "${KTHW_ZONE}" || "${KTHW_ZONE}" == "(unset)" ]]; then
  echo "CRITICAL: compute/zone is not configured. Run: gcloud config set compute/zone <zone>"
  exit 1
fi

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

# Helper: create the GCP VPC route for a worker pod CIDR if needed.
_ensure_gcp_route() {
  local name="$1" subnet="$2" instance="$3"

  if gcloud compute routes describe "${name}" >/dev/null 2>&1; then
    echo "  GCP route ${name} for ${subnet} already present — skipping."
  else
    gcloud compute routes create "${name}" \
      --network "${NETWORK_NAME}" \
      --destination-range "${subnet}" \
      --next-hop-instance "${instance}" \
      --next-hop-instance-zone "${KTHW_ZONE}"
    echo "  Created GCP route ${name}: ${subnet} -> ${instance}"
  fi
}

# Helper: remove old direct Linux pod routes from earlier versions of this repo.
_remove_stale_linux_route() {
  local host="$1" subnet="$2"
  ssh "${SSH_OPTS[@]}" "root@${host}" bash -s <<REMOTE
set -euo pipefail

if ip route show | grep -q "^${subnet}"; then
  ip route del "${subnet}" 2>/dev/null || true
  echo "  Removed stale Linux route for ${subnet}"
else
  echo "  No stale Linux route for ${subnet}"
fi

PERSIST_FILE="/etc/network/interfaces.d/kthw-pod-routes.cfg"
if [[ -f "\${PERSIST_FILE}" ]]; then
  sed -i "\\|${subnet}|d" "\${PERSIST_FILE}"
  echo "  Removed stale persistence entries for ${subnet}"
fi
REMOTE
}

# Helper: enable IP forwarding and loose reverse-path filtering on workers.
# Required for cross-node pod traffic (10.200.x → 10.200.x) after reboot.
# Without ip_forward=1 packets between pod subnets are dropped.
# Strict rp_filter=1 rejects asymmetric return paths common in routed pod setups.
_configure_forwarding() {
  local host="$1"
  ssh "${SSH_OPTS[@]}" "root@${host}" bash -s <<'REMOTE'
set -euo pipefail

SYSCTL_FILE="/etc/sysctl.d/kubernetes.conf"
mkdir -p /etc/sysctl.d

while read -r param val; do
  if grep -qxF "${param} = ${val}" "${SYSCTL_FILE}" 2>/dev/null; then
    echo "  ${param} already set — skipping."
  else
    # Remove any previous value for this param, then append the correct one.
    if [[ -f "${SYSCTL_FILE}" ]]; then
      sed -i "/^${param//./\\.}/d" "${SYSCTL_FILE}"
    fi
    echo "${param} = ${val}" >> "${SYSCTL_FILE}"
    echo "  Set ${param} = ${val}"
  fi
done <<'SYSCTL_SETTINGS'
net.ipv4.ip_forward 1
net.ipv4.conf.all.rp_filter 2
net.ipv4.conf.default.rp_filter 2
SYSCTL_SETTINGS

sysctl -p "${SYSCTL_FILE}" >/dev/null
echo "  ip_forward=$(sysctl -n net.ipv4.ip_forward)  rp_filter=$(sysctl -n net.ipv4.conf.all.rp_filter)"
REMOTE
}

echo ""
echo "=== [2/5] Configuring IP forwarding on workers ==="

echo "  --- node-0 ---"
_configure_forwarding node-0

echo "  --- node-1 ---"
_configure_forwarding node-1

# ------------------------------------------------------------------------------
# Add routes — each machine gets routes to all OTHER nodes' pod subnets
# ------------------------------------------------------------------------------
echo ""
echo ""
echo "=== [3/5] Creating GCP VPC pod CIDR routes ==="
_ensure_gcp_route "kubernetes-route-10-200-0-0-24" "${NODE_0_SUBNET}" "node-0"
_ensure_gcp_route "kubernetes-route-10-200-1-0-24" "${NODE_1_SUBNET}" "node-1"

echo ""
echo "=== [4/5] Removing stale direct Linux pod routes ==="

echo "  --- server ---"
_remove_stale_linux_route server "${NODE_0_SUBNET}"
_remove_stale_linux_route server "${NODE_1_SUBNET}"

echo "  --- node-0 ---"
_remove_stale_linux_route node-0 "${NODE_1_SUBNET}"

echo "  --- node-1 ---"
_remove_stale_linux_route node-1 "${NODE_0_SUBNET}"

echo ""
echo "=== [5/5] Route table summary ==="
for host in server node-0 node-1; do
  echo "  --- ${host} ---"
  ssh "${SSH_OPTS[@]}" "root@${host}" \
    "ip route show | awk '/10\\.200\\./ { found = 1; print } END { if (!found) print \"  (no pod routes found)\" }'"
done

echo ""
echo "=== Pod network routes configured ==="
echo "Next: run ./scripts/11-pod-routes/verify-pod-routes.sh"
