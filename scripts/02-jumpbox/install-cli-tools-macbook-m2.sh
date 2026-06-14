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
TARGET_ARCH="amd64"   # Linux node binaries — GCP e2-small instances are x86_64
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOWNLOADS_DIR="${ROOT_DIR}/kthw-downloads"

# Download URLs are generated from the version variables above.
# Override any version at runtime, e.g:
#   KUBERNETES_VERSION=v1.33.1 ./install-cli-tools-macbook-m2.sh --force
DOWNLOAD_URLS=(
  "https://dl.k8s.io/${KUBERNETES_VERSION}/bin/linux/${TARGET_ARCH}/kubectl"
  "https://dl.k8s.io/${KUBERNETES_VERSION}/bin/linux/${TARGET_ARCH}/kube-apiserver"
  "https://dl.k8s.io/${KUBERNETES_VERSION}/bin/linux/${TARGET_ARCH}/kube-controller-manager"
  "https://dl.k8s.io/${KUBERNETES_VERSION}/bin/linux/${TARGET_ARCH}/kube-scheduler"
  "https://dl.k8s.io/${KUBERNETES_VERSION}/bin/linux/${TARGET_ARCH}/kube-proxy"
  "https://dl.k8s.io/${KUBERNETES_VERSION}/bin/linux/${TARGET_ARCH}/kubelet"
  "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${TARGET_ARCH}.tar.gz"
  "https://github.com/opencontainers/runc/releases/download/v1.3.5/runc.${TARGET_ARCH}"
  "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${TARGET_ARCH}-${CNI_PLUGINS_VERSION}.tgz"
  "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-${TARGET_ARCH}.tar.gz"
  "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-${TARGET_ARCH}.tar.gz"
)

FORCE=false
for arg in "$@"; do
  [[ "${arg}" == "--force" ]] && FORCE=true
done

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
_kubectl_version_ok() {
  [[ -x "${INSTALL_BIN}/kubectl" ]] && \
    "${INSTALL_BIN}/kubectl" version --client 2>/dev/null | grep -q "${KUBERNETES_VERSION}"
}

if ! ${FORCE} && _kubectl_version_ok; then
  echo "kubectl ${KUBERNETES_VERSION} already installed at ${INSTALL_BIN}/kubectl — skipping download."
else
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
fi

echo "=== [4/6] Downloading Linux ${TARGET_ARCH} Kubernetes node binaries ==="
mkdir -p "${DOWNLOADS_DIR}"

# Build a filtered list of URLs whose target files are not yet present
MISSING_URLS=()
for url in "${DOWNLOAD_URLS[@]}"; do
  filename="$(basename "${url}")"
  if ! ${FORCE} && [[ -f "${DOWNLOADS_DIR}/${filename}" ]]; then
    echo "Already downloaded: ${filename} — skipping."
  else
    MISSING_URLS+=("${url}")
  fi
done

if [[ ${#MISSING_URLS[@]} -gt 0 ]]; then
  printf '%s\n' "${MISSING_URLS[@]}" | wget -q --show-progress \
    --https-only \
    -P "${DOWNLOADS_DIR}" \
    -i -
else
  echo "All downloads already present — skipping wget."
fi

echo "=== [5/6] Organizing downloaded binaries ==="
_organized_ok() {
  [[ -x "${DOWNLOADS_DIR}/client/kubectl" ]]            && \
  [[ -x "${DOWNLOADS_DIR}/client/etcdctl" ]]            && \
  [[ -x "${DOWNLOADS_DIR}/controller/kube-apiserver" ]] && \
  [[ -x "${DOWNLOADS_DIR}/controller/etcd" ]]           && \
  [[ -x "${DOWNLOADS_DIR}/worker/kubelet" ]]            && \
  [[ -x "${DOWNLOADS_DIR}/worker/crictl" ]]             && \
  [[ -x "${DOWNLOADS_DIR}/worker/runc" ]]
}

if ! ${FORCE} && _organized_ok; then
  echo "Organized binaries already present — skipping extraction and layout."
else
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
fi

echo "=== [6/6] Verifying kubectl ==="
"${INSTALL_BIN}/kubectl" version --client

echo "=== Jumpbox CLI tools are ready on this MacBook Air M2 ==="
echo "Linux ${TARGET_ARCH} node binaries are organized under: ${DOWNLOADS_DIR}"
