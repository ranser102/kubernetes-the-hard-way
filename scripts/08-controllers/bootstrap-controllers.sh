#!/usr/bin/env bash

# ==============================================================================
# KTHW CONTROL PLANE — Install, configure, and start control plane on server
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CERTS_DIR="${ROOT_DIR}/scripts/certs"
SSH_KEY="${KTHW_SSH_KEY_PATH:-${HOME}/.ssh/google_compute_engine}"

FORCE=false
for arg in "$@"; do
  [[ "${arg}" == "--force" ]] && FORCE=true
done

SSH_OPTS=(
  -i "${SSH_KEY}"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
)

_remote_run() {
  ssh "${SSH_OPTS[@]}" root@server bash -s "$@"
}

echo "=== [1/4] Installing control plane binaries ==="
_remote_run <<REMOTE
set -euo pipefail
FORCE="${FORCE}"

_bin_ok() {
  local bin="\$1"
  [[ -x /usr/local/bin/\${bin} ]] || return 1
  if [[ "\${bin}" == "kubectl" ]]; then
    /usr/local/bin/kubectl version --client >/dev/null 2>&1
  else
    /usr/local/bin/\${bin} --version >/dev/null 2>&1
  fi
}

mkdir -p /etc/kubernetes/config

for bin in kube-apiserver kube-controller-manager kube-scheduler kubectl; do
  if [[ "\${FORCE}" != "true" ]] && _bin_ok "\${bin}"; then
    echo "\${bin} already installed and executable — skipping."
  elif [[ -f ~/\${bin} ]]; then
    mv -f ~/\${bin} /usr/local/bin/
    chmod +x /usr/local/bin/\${bin}
    echo "Installed: \${bin}"
  elif _bin_ok "\${bin}"; then
    echo "\${bin} already at /usr/local/bin/ (no staged file in ~/) — skipping."
  else
    echo "ERROR: \${bin} not found in ~/ and not installed. Run copy-controller-files.sh first."
    exit 1
  fi
done
REMOTE

echo "=== [2/4] Configuring API server, controller manager, and scheduler ==="
_remote_run <<REMOTE
set -euo pipefail
FORCE="${FORCE}"

mkdir -p /var/lib/kubernetes/

_place() {
  local src="\$1" dest="\$2"
  local name="\$(basename "\${src}")"
  if [[ "\${FORCE}" != "true" ]] && [[ -f "\${dest}" ]]; then
    echo "Already in place: \${dest} — skipping."
  elif [[ -f "\${src}" ]]; then
    mv -f "\${src}" "\${dest}"
    echo "Placed: \${dest}"
  elif [[ -f "\${dest}" ]]; then
    echo "Already in place: \${dest} (no staged file in ~/) — skipping."
  else
    echo "ERROR: \${name} not found in ~/ and not at \${dest}. Run copy-controller-files.sh first."
    exit 1
  fi
}

# Certs and encryption config
for f in ca.crt ca.key kube-api-server.key kube-api-server.crt \
          service-accounts.key service-accounts.crt encryption-config.yaml; do
  _place ~/\${f} /var/lib/kubernetes/\${f}
done

# Kubeconfigs
for f in kube-controller-manager.kubeconfig kube-scheduler.kubeconfig; do
  _place ~/\${f} /var/lib/kubernetes/\${f}
done

# Scheduler config
_place ~/kube-scheduler.yaml /etc/kubernetes/config/kube-scheduler.yaml

# Unit files
for unit in kube-apiserver.service kube-controller-manager.service kube-scheduler.service; do
  _place ~/\${unit} /etc/systemd/system/\${unit}
done
REMOTE

echo "=== [3/4] Enabling and starting control plane services ==="
_remote_run <<REMOTE
set -euo pipefail
FORCE="${FORCE}"

systemctl daemon-reload
systemctl enable kube-apiserver kube-controller-manager kube-scheduler

for svc in kube-apiserver kube-controller-manager kube-scheduler; do
  if [[ "\${FORCE}" == "true" ]]; then
    systemctl restart "\${svc}" || {
      echo "--- \${svc} failed; journal: ---"
      journalctl -xeu "\${svc}" --no-pager | tail -30
      exit 1
    }
  elif systemctl is-active --quiet "\${svc}"; then
    echo "\${svc} already running — skipping start."
  else
    systemctl start "\${svc}" || {
      echo "--- \${svc} failed; journal: ---"
      journalctl -xeu "\${svc}" --no-pager | tail -30
      exit 1
    }
  fi
done

echo "Waiting up to 15s for kube-apiserver to initialize..."
for i in \$(seq 1 15); do
  systemctl is-active --quiet kube-apiserver && break
  sleep 1
done
REMOTE

echo "=== [4/4] Applying RBAC for kubelet authorization ==="
_remote_run <<'REMOTE'
set -euo pipefail
kubectl apply -f ~/kube-apiserver-to-kubelet.yaml \
  --kubeconfig ~/admin.kubeconfig
REMOTE

echo "=== Verifying control plane ==="
ssh "${SSH_OPTS[@]}" root@server \
  "kubectl cluster-info --kubeconfig ~/admin.kubeconfig"

echo ""
echo "=== Verifying API server from local machine ==="
curl --silent --cacert "${CERTS_DIR}/ca.crt" \
  https://server.kubernetes.local:6443/version | grep gitVersion

echo "=== Control plane is bootstrapped successfully ==="
echo "Next: ./scripts/09-workers/bootstrap-workers.sh"
