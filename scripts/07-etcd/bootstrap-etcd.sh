#!/usr/bin/env bash

# ==============================================================================
# KTHW ETCD — Install, configure, and start etcd on server (runs locally,
#              executes commands remotely via ssh)
# ==============================================================================
set -euo pipefail

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

echo "=== [1/3] Installing etcd binaries ==="
_remote_run <<REMOTE
set -euo pipefail
FORCE="${FORCE}"
_etcd_ok() {
  [[ -x /usr/local/bin/etcd ]] && /usr/local/bin/etcd --version >/dev/null 2>&1
}
if [[ "\${FORCE}" != "true" ]] && _etcd_ok; then
  echo "etcd already installed and executable — skipping. (use --force to reinstall)"
else
  mv -f ~/etcd ~/etcdctl /usr/local/bin/
  chmod +x /usr/local/bin/etcd /usr/local/bin/etcdctl
  echo "Installed: \$(/usr/local/bin/etcd --version | head -1)"
fi
REMOTE

echo "=== [2/3] Configuring etcd ==="
_remote_run <<'REMOTE'
set -euo pipefail

mkdir -p /etc/etcd /var/lib/etcd
chmod 700 /var/lib/etcd

# Copy certs only if not already in place
for f in ca.crt kube-api-server.key kube-api-server.crt; do
  if [[ -f "/etc/etcd/${f}" ]]; then
    echo "Already exists: /etc/etcd/${f} — skipping."
  else
    cp ~/"${f}" /etc/etcd/
    echo "Copied: /etc/etcd/${f}"
  fi
done

# Install unit file
if [[ -f /etc/systemd/system/etcd.service ]]; then
  echo "Already exists: /etc/systemd/system/etcd.service — skipping."
else
  mv ~/etcd.service /etc/systemd/system/
  echo "Installed: /etc/systemd/system/etcd.service"
fi
REMOTE

echo "=== [3/3] Enabling and starting etcd ==="
_remote_run <<REMOTE
set -euo pipefail
FORCE="${FORCE}"
systemctl daemon-reload
systemctl enable etcd

if [[ "\${FORCE}" == "true" ]]; then
  systemctl restart etcd || {
    echo "--- etcd failed to start; last 40 journal lines: ---"
    journalctl -xeu etcd.service --no-pager | tail -40
    exit 1
  }
elif systemctl is-active --quiet etcd; then
  echo "etcd is already running — skipping start."
else
  systemctl start etcd || {
    echo "--- etcd failed to start; last 40 journal lines: ---"
    journalctl -xeu etcd.service --no-pager | tail -40
    exit 1
  }
fi
REMOTE

echo "=== Verifying etcd cluster members ==="
ssh "${SSH_OPTS[@]}" root@server \
  "etcdctl member list"

echo "=== etcd bootstrapped successfully ==="
echo "Next: ./scripts/08-controllers/bootstrap-kubernetes-controllers.sh"
