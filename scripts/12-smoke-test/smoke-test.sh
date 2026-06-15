#!/usr/bin/env bash

# ==============================================================================
# KTHW SMOKE TEST — End-to-end cluster verification
# Runs on: jumpbox/local machine
#
# Tests in order:
#   1. Data encryption at rest  — secret stored encrypted in etcd
#   2. Deployments              — nginx pod schedules and reaches Running
#   3. Port forwarding          — kubectl port-forward reaches the pod
#   4. Logs                     — kubectl logs returns output
#   5. Exec                     — kubectl exec runs a command in the container
#   6. NodePort service         — pod reachable via node external IP + NodePort
# ==============================================================================
set -euo pipefail

SSH_KEY="${KTHW_SSH_KEY_PATH:-${HOME}/.ssh/google_compute_engine}"
SSH_OPTS=(-i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

PASS=0
FAIL=0

_pass() { echo "  PASS: $*"; (( PASS++ )) || true; }
_fail() { echo "  FAIL: $*"; (( FAIL++ )) || true; }

# ==============================================================================
# TEST 1 — Data encryption at rest
# Runs on: server/control-plane (via SSH)
#
# Creates a Kubernetes Secret, then reads the raw bytes directly from etcd.
# If encryption is working, the etcd value starts with k8s:enc:aescbc:v1:key1
# (the encryption provider name + key identifier) instead of plaintext JSON.
# This confirms the encryption-config.yaml from step 06 is active.
# ==============================================================================
echo "=== [1/6] Data encryption at rest ==="

# Create (or skip if already exists) a test secret
kubectl create secret generic kubernetes-the-hard-way \
  --from-literal="mykey=mydata" 2>/dev/null || echo "  Secret already exists — skipping create."

# Read the raw etcd value and check for the encryption prefix
ETCD_OUTPUT="$(ssh "${SSH_OPTS[@]}" root@server \
  "etcdctl get /registry/secrets/default/kubernetes-the-hard-way | hexdump -C" 2>/dev/null)"
echo "${ETCD_OUTPUT}" | head -5

# The string k8s:enc:aescbc:v1:key1 spans two hexdump lines — match on the
# portion that fits within a single line (k8s:enc:aescbc is sufficient)
if echo "${ETCD_OUTPUT}" | grep -q "k8s:enc:aescbc"; then
  _pass "Secret is encrypted at rest (aescbc provider, key1)"
else
  _fail "Secret does NOT appear to be encrypted — check encryption-config.yaml on server"
fi

# ==============================================================================
# TEST 2 — Deployments
# Runs on: jumpbox/local machine (kubectl) + workers schedule the pod
#
# Creates an nginx Deployment and waits up to 60s for the pod to reach Running.
# Verifies that: the scheduler assigned the pod to a node, kubelet pulled the
# image, and containerd started the container successfully.
# ==============================================================================
echo ""
echo "=== [2/6] Deployments ==="

# Create nginx deployment (idempotent — skip if exists)
kubectl create deployment nginx --image=nginx:latest 2>/dev/null \
  || echo "  Deployment already exists — skipping create."

echo "  Waiting up to 60s for nginx pod to be Running..."
kubectl wait pod -l app=nginx --for=condition=Ready --timeout=60s

POD_NAME="$(kubectl get pods -l app=nginx -o jsonpath='{.items[0].metadata.name}')"
POD_STATUS="$(kubectl get pod "${POD_NAME}" -o jsonpath='{.status.phase}')"
if [[ "${POD_STATUS}" == "Running" ]]; then
  _pass "nginx pod ${POD_NAME} is Running"
else
  _fail "nginx pod ${POD_NAME} status is ${POD_STATUS}"
fi

# ==============================================================================
# TEST 3 — Port forwarding
# Runs on: jumpbox/local machine
#
# Starts kubectl port-forward in the background (tunnels local 18080 → pod:80).
# Then curls through the tunnel. This verifies:
#   - The socat binary on the worker (required for port-forward) works
#   - The pod's nginx is actually serving HTTP
# Uses port 18080 to avoid conflicts with any local port 8080.
# ==============================================================================
echo ""
echo "=== [3/6] Port forwarding ==="

# Kill any leftover port-forward from a previous run
pkill -f "kubectl port-forward ${POD_NAME}" 2>/dev/null || true
sleep 1

pkill -f "port-forward.*18080" 2>/dev/null || true
kubectl port-forward "${POD_NAME}" 18080:80 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT

# Poll until the tunnel is ready (up to 15s)
HTTP_STATUS="000"
for i in $(seq 1 15); do
  HTTP_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 2 http://127.0.0.1:18080 2>/dev/null || true)"
  [[ "${HTTP_STATUS}" == "200" ]] && break
  sleep 1
done
kill "${PF_PID}" 2>/dev/null || true

if [[ "${HTTP_STATUS}" == "200" ]]; then
  _pass "port-forward returned HTTP 200 from nginx"
else
  _fail "port-forward returned HTTP ${HTTP_STATUS:-no response} (expected 200)"
fi

# ==============================================================================
# TEST 4 — Container logs
# Runs on: jumpbox/local machine (kubectl fetches logs from kubelet API)
#
# Retrieves logs from the nginx container. The curl request in TEST 3 should
# have generated an access log line. Verifies that:
#   - kubelet's log endpoint is reachable by kube-apiserver (RBAC from step 08)
#   - The container wrote to stdout (nginx access log)
# ==============================================================================
echo ""
echo "=== [4/6] Container logs ==="

LOGS="$(kubectl logs "${POD_NAME}" 2>/dev/null || true)"
if [[ -n "${LOGS}" ]]; then
  echo "  Log sample: $(echo "${LOGS}" | tail -1)"
  _pass "kubectl logs returned output for ${POD_NAME}"
else
  _fail "kubectl logs returned no output — check RBAC (kube-apiserver-to-kubelet)"
fi

# ==============================================================================
# TEST 5 — Exec into container
# Runs on: jumpbox/local machine (kubectl exec → kubelet → containerd → pod)
#
# Runs nginx -v inside the container. Verifies the full exec path:
#   kube-apiserver → kubelet API → containerd exec → container process
# This is the deepest integration test — if this works, the entire stack is
# functioning correctly end to end.
# ==============================================================================
echo ""
echo "=== [5/6] Exec into container ==="

NGINX_VERSION="$(kubectl exec "${POD_NAME}" -- nginx -v 2>&1 || true)"
if echo "${NGINX_VERSION}" | grep -q "nginx version"; then
  _pass "kubectl exec: ${NGINX_VERSION}"
else
  _fail "kubectl exec failed: ${NGINX_VERSION:-no output}"
fi

# ==============================================================================
# TEST 6 — NodePort service
# Runs on: jumpbox/local machine (curl to node's external IP + NodePort)
#
# Exposes the nginx deployment as a NodePort Service. kube-proxy on the worker
# installs iptables rules to forward traffic from <node-ip>:<node-port> to the
# pod. Verifies that:
#   - kube-proxy is correctly setting up iptables rules
#   - The node's external IP is reachable on the assigned NodePort (30000-32767)
# ==============================================================================
echo ""
echo "=== [6/6] NodePort service ==="

# Create NodePort service (idempotent)
kubectl expose deployment nginx --port 80 --type NodePort 2>/dev/null \
  || echo "  Service already exists — skipping create."

NODE_PORT="$(kubectl get svc nginx -o jsonpath='{.spec.ports[0].nodePort}')"
NODE_NAME="$(kubectl get pods -l app=nginx -o jsonpath='{.items[0].spec.nodeName}')"
echo "  NodePort: ${NODE_PORT}  Node: ${NODE_NAME}"

# GCP firewall only opens ports 22 and 6443 from outside the VPC.
# NodePorts (30000-32767) are blocked from the jumpbox/local machine.
# Test from server (inside the VPC) using the node's internal IP instead.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NODE_INTERNAL_IP="$(grep "[[:space:]]${NODE_NAME}$" "${ROOT_DIR}/scripts/hosts.internal" | awk '{print $1}')"
echo "  Testing via server → ${NODE_INTERNAL_IP}:${NODE_PORT} (internal VPC)"

# Give kube-proxy a moment to install iptables rules
sleep 3

HTTP_STATUS="$(ssh "${SSH_OPTS[@]}" root@server \
  "curl --silent --output /dev/null --write-out '%{http_code}' \
   --connect-timeout 10 http://${NODE_INTERNAL_IP}:${NODE_PORT}" 2>/dev/null || true)"

if [[ "${HTTP_STATUS}" == "200" ]]; then
  _pass "NodePort service returned HTTP 200 (node=${NODE_NAME} internal=${NODE_INTERNAL_IP} port=${NODE_PORT})"
else
  _fail "NodePort returned HTTP ${HTTP_STATUS:-no response} — check kube-proxy iptables rules on ${NODE_NAME}"
fi

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "=== Smoke Test Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo ""
echo "  Deployment : nginx (keep running for upgrade simulation in step 14)"
echo "  Secret     : kubernetes-the-hard-way"
echo "  Service    : nginx NodePort ${NODE_PORT:-unknown}"
echo ""
if [[ ${FAIL} -eq 0 ]]; then
  echo "=== All smoke tests passed — cluster is fully functional ==="
  echo "Next: ./scripts/14-upgrade/  (upgrade simulation) or ./scripts/13-cleanup/cleanup.sh"
else
  echo "=== ${FAIL} test(s) failed — review output above ==="
  exit 1
fi
