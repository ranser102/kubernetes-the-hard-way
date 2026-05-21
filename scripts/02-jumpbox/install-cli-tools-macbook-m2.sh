#!/usr/bin/env bash

# ==============================================================================
# KTHW JUMPBOX CLI TOOLS FOR MACBOOK AIR M2
# ==============================================================================
set -euo pipefail

KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.32.13}"
CRICTL_VERSION="${CRICTL_VERSION:-v1.32.0}"
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-v1.6.2}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.1.7}"
ETCD_VERSION="${ETCD_VERSION:-v3.6.11}"
TARGET_ARCH="arm64"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOWNLOADS_DIR="${ROOT_DIR}/ktwh-downloads"
DOWNLOAD_LIST="${SCRIPT_DIR}/downloads-${TARGET_ARCH}.txt"

echo "=== [1/6] Validating macOS Apple Silicon workstation ==="
if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "CRITICAL: This script is intended for macOS on Apple Silicon (arm64)."
  echo "Detected: $(uname -s) $(uname -m)"
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "CRITICAL: Homebrew is required."
  echo "Install it from https://brew.sh, then rerun this script."
  exit 1
fi

BREW_PREFIX="$(brew --prefix)"
INSTALL_BIN="${KTHW_INSTALL_BIN:-${BREW_PREFIX}/bin}"

echo "=== [2/6] Installing jumpbox command line utilities ==="
for formula in wget git vim openssl@3; do
  if brew list --formula "${formula}" >/dev/null 2>&1; then
    echo "Already installed: ${formula}"
  else
    brew install "${formula}"
  fi
done

echo "=== [3/6] Installing kubectl ${KUBERNETES_VERSION} for macOS arm64 ==="
KUBECTL_TMP="$(mktemp)"
trap 'rm -f "${KUBECTL_TMP}"' EXIT

curl -fL --retry 3 \
  -o "${KUBECTL_TMP}" \
  "https://dl.k8s.io/${KUBERNETES_VERSION}/bin/darwin/arm64/kubectl"
chmod +x "${KUBECTL_TMP}"

mkdir -p "${INSTALL_BIN}"
if [[ -w "${INSTALL_BIN}" ]]; then
  install -m 0755 "${KUBECTL_TMP}" "${INSTALL_BIN}/kubectl"
else
  sudo install -m 0755 "${KUBECTL_TMP}" "${INSTALL_BIN}/kubectl"
fi

echo "=== [4/6] Downloading Linux arm64 Kubernetes node binaries ==="
if [[ ! -f "${DOWNLOAD_LIST}" ]]; then
  echo "CRITICAL: Missing ${DOWNLOAD_LIST}"
  exit 1
fi

mkdir -p "${DOWNLOADS_DIR}"
wget -q --show-progress \
  --https-only \
  --timestamping \
  -P "${DOWNLOADS_DIR}" \
  -i "${DOWNLOAD_LIST}"

echo "=== [5/6] Organizing downloaded binaries ==="
rm -rf \
  "${DOWNLOADS_DIR}/client" \
  "${DOWNLOADS_DIR}/cni-plugins" \
  "${DOWNLOADS_DIR}/controller" \
  "${DOWNLOADS_DIR}/worker"
mkdir -p \
  "${DOWNLOADS_DIR}/client" \
  "${DOWNLOADS_DIR}/cni-plugins" \
  "${DOWNLOADS_DIR}/controller" \
  "${DOWNLOADS_DIR}/worker"

tar -xvf "${DOWNLOADS_DIR}/crictl-${CRICTL_VERSION}-linux-${TARGET_ARCH}.tar.gz" \
  -C "${DOWNLOADS_DIR}/worker/"
tar -xvf "${DOWNLOADS_DIR}/containerd-${CONTAINERD_VERSION}-linux-${TARGET_ARCH}.tar.gz" \
  --strip-components 1 \
  -C "${DOWNLOADS_DIR}/worker/"
tar -xvf "${DOWNLOADS_DIR}/cni-plugins-linux-${TARGET_ARCH}-${CNI_PLUGINS_VERSION}.tgz" \
  -C "${DOWNLOADS_DIR}/cni-plugins/"
tar -xvf "${DOWNLOADS_DIR}/etcd-${ETCD_VERSION}-linux-${TARGET_ARCH}.tar.gz" \
  -C "${DOWNLOADS_DIR}/" \
  --strip-components 1 \
  "etcd-${ETCD_VERSION}-linux-${TARGET_ARCH}/etcdctl" \
  "etcd-${ETCD_VERSION}-linux-${TARGET_ARCH}/etcd"

mv "${DOWNLOADS_DIR}/etcdctl" "${DOWNLOADS_DIR}/kubectl" \
  "${DOWNLOADS_DIR}/client/"
mv \
  "${DOWNLOADS_DIR}/etcd" \
  "${DOWNLOADS_DIR}/kube-apiserver" \
  "${DOWNLOADS_DIR}/kube-controller-manager" \
  "${DOWNLOADS_DIR}/kube-scheduler" \
  "${DOWNLOADS_DIR}/controller/"
mv \
  "${DOWNLOADS_DIR}/kubelet" \
  "${DOWNLOADS_DIR}/kube-proxy" \
  "${DOWNLOADS_DIR}/worker/"
mv "${DOWNLOADS_DIR}/runc.${TARGET_ARCH}" "${DOWNLOADS_DIR}/worker/runc"

chmod +x \
  "${DOWNLOADS_DIR}/client/"* \
  "${DOWNLOADS_DIR}/cni-plugins/"* \
  "${DOWNLOADS_DIR}/controller/"* \
  "${DOWNLOADS_DIR}/worker/"*

echo "=== [6/6] Verifying kubectl ==="
"${INSTALL_BIN}/kubectl" version --client

echo "=== Jumpbox CLI tools are ready on this MacBook Air M2 ==="
echo "Linux arm64 node binaries are organized under: ${DOWNLOADS_DIR}"
