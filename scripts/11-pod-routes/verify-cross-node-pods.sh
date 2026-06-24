#!/usr/bin/env bash

# ==============================================================================
# KTHW POD NETWORK ROUTES — Cross-node pod-to-pod verification
# Runs on: jumpbox/local machine
#
# This verifies the real routed pod network path:
#   busybox on node-0 -> nginx Pod IP on node-1
#   busybox on node-1 -> nginx Pod IP on node-0
#
# It intentionally uses direct Pod IPs, not Services, NodePorts, ClusterIPs, or
# DNS. This catches failures in routing between 10.200.0.0/24 and 10.200.1.0/24.
# ==============================================================================
set -euo pipefail

NAMESPACE="${CROSS_NODE_TEST_NAMESPACE:-kthw-nettest}"
READY_TIMEOUT="${CROSS_NODE_TEST_READY_TIMEOUT:-180s}"
CLEANUP="${CROSS_NODE_TEST_CLEANUP:-false}"

PASS=0
FAIL=0

_pass() { echo "  PASS: $*"; (( PASS++ )) || true; }
_fail() { echo "  FAIL: $*"; (( FAIL++ )) || true; }

cleanup() {
  if [[ "${CLEANUP}" == "true" ]]; then
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_deployment() {
  local name="$1"
  kubectl -n "${NAMESPACE}" rollout status "deployment/${name}" --timeout="${READY_TIMEOUT}"
}

pod_name_for_app() {
  local app="$1"
  kubectl -n "${NAMESPACE}" get pod \
    -l "app=${app}" \
    -o jsonpath='{.items[0].metadata.name}'
}

pod_ip_for_app() {
  local app="$1"
  kubectl -n "${NAMESPACE}" get pod \
    -l "app=${app}" \
    -o jsonpath='{.items[0].status.podIP}'
}

node_for_app() {
  local app="$1"
  kubectl -n "${NAMESPACE}" get pod \
    -l "app=${app}" \
    -o jsonpath='{.items[0].spec.nodeName}'
}

test_http_from_busybox() {
  local source_app="$1"
  local target_app="$2"
  local target_ip="$3"
  local source_pod

  source_pod="$(pod_name_for_app "${source_app}")"
  if kubectl -n "${NAMESPACE}" exec "${source_pod}" -- \
      wget -q -O- -T 5 "http://${target_ip}" >/dev/null 2>&1; then
    _pass "${source_app} reached ${target_app} directly at ${target_ip}:80"
  else
    _fail "${source_app} could not reach ${target_app} directly at ${target_ip}:80"
  fi
}

echo "=== [1/4] Creating cross-node test namespace ==="
kubectl create namespace "${NAMESPACE}" 2>/dev/null \
  || echo "  Namespace ${NAMESPACE} already exists — reusing."

echo ""
echo "=== [2/4] Deploying pinned test workloads ==="
kubectl apply -n "${NAMESPACE}" -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-node-0
  labels:
    app: nginx-node-0
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-node-0
  template:
    metadata:
      labels:
        app: nginx-node-0
    spec:
      nodeSelector:
        kubernetes.io/hostname: node-0
      containers:
        - name: nginx
          image: nginx:latest
          ports:
            - containerPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-node-1
  labels:
    app: nginx-node-1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-node-1
  template:
    metadata:
      labels:
        app: nginx-node-1
    spec:
      nodeSelector:
        kubernetes.io/hostname: node-1
      containers:
        - name: nginx
          image: nginx:latest
          ports:
            - containerPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: busybox-node-0
  labels:
    app: busybox-node-0
spec:
  replicas: 1
  selector:
    matchLabels:
      app: busybox-node-0
  template:
    metadata:
      labels:
        app: busybox-node-0
    spec:
      nodeSelector:
        kubernetes.io/hostname: node-0
      containers:
        - name: busybox
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: busybox-node-1
  labels:
    app: busybox-node-1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: busybox-node-1
  template:
    metadata:
      labels:
        app: busybox-node-1
    spec:
      nodeSelector:
        kubernetes.io/hostname: node-1
      containers:
        - name: busybox
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
EOF

echo ""
echo "=== [3/4] Waiting for test workloads ==="
for deployment in nginx-node-0 nginx-node-1 busybox-node-0 busybox-node-1; do
  wait_for_deployment "${deployment}"
done

NGINX_NODE_0_IP="$(pod_ip_for_app nginx-node-0)"
NGINX_NODE_1_IP="$(pod_ip_for_app nginx-node-1)"

echo ""
echo "  nginx-node-0:  podIP=${NGINX_NODE_0_IP}  node=$(node_for_app nginx-node-0)"
echo "  nginx-node-1:  podIP=${NGINX_NODE_1_IP}  node=$(node_for_app nginx-node-1)"
echo "  busybox-node-0: node=$(node_for_app busybox-node-0)"
echo "  busybox-node-1: node=$(node_for_app busybox-node-1)"

echo ""
echo "=== [4/4] Testing direct cross-node Pod IP connectivity ==="
test_http_from_busybox busybox-node-0 nginx-node-1 "${NGINX_NODE_1_IP}"
test_http_from_busybox busybox-node-1 nginx-node-0 "${NGINX_NODE_0_IP}"

echo ""
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"
if [[ ${FAIL} -eq 0 ]]; then
  echo "=== Cross-node pod-to-pod verification passed ==="
else
  echo "=== ${FAIL} cross-node pod check(s) failed — review pod routes, sysctl, and CNI bridge state ==="
  exit 1
fi
