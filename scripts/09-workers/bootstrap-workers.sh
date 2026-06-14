#!/usr/bin/env bash

# ==============================================================================
# KTHW WORKER NODES — Install and configure kubelet, kube-proxy, containerd,
#                     CNI plugins, and runc on node-0 and node-1
# Runs on: jumpbox/local machine (executes commands on workers via SSH)
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

# Run a heredoc script on a specific worker node via SSH
_remote_run() {
  local host="$1"; shift
  ssh "${SSH_OPTS[@]}" "root@${host}" bash -s "$@"
}

for node in node-0 node-1; do
  echo "======================================================"
  echo "  Bootstrapping worker: ${node}"
  echo "======================================================"

  # ----------------------------------------------------------------------------
  # STEP 1 — Install OS dependencies
  # socat   : enables kubectl port-forward
  # conntrack: required by kube-proxy for connection tracking
  # ipset   : used by kube-proxy for efficient iptables rule sets
  # kmod    : provides modprobe for loading kernel modules
  # ----------------------------------------------------------------------------
  echo "--- [1/7] Installing OS dependencies on ${node} ---"
  _remote_run "${node}" <<'REMOTE'
set -euo pipefail
apt-get update -qq
apt-get -y install -qq socat conntrack ipset kmod
REMOTE

  # ----------------------------------------------------------------------------
  # STEP 2 — Disable swap
  # Kubernetes requires swap to be off; it cannot account for pod memory usage
  # when swap is active. Also persist the setting across reboots via /etc/fstab.
  # ----------------------------------------------------------------------------
  echo "--- [2/7] Disabling swap on ${node} ---"
  _remote_run "${node}" <<'REMOTE'
set -euo pipefail
swapoff -a
# Remove any swap entries from /etc/fstab so it stays off after reboot
sed -i '/\bswap\b/d' /etc/fstab
echo "Swap disabled."
REMOTE

  # ----------------------------------------------------------------------------
  # STEP 3 — Create installation directories
  # Standard paths expected by kubelet, kube-proxy, containerd, and CNI.
  # ----------------------------------------------------------------------------
  echo "--- [3/7] Creating installation directories on ${node} ---"
  _remote_run "${node}" <<'REMOTE'
set -euo pipefail
mkdir -p \
  /etc/cni/net.d \
  /opt/cni/bin \
  /var/lib/kubelet \
  /var/lib/kube-proxy \
  /var/lib/kubernetes \
  /var/run/kubernetes \
  /etc/containerd
REMOTE

  # ----------------------------------------------------------------------------
  # STEP 4 — Install worker binaries
  # Moves staged binaries from ~/ into their final system locations.
  # - crictl, kube-proxy, kubelet, runc → /usr/local/bin/
  # - containerd* → /bin/  (containerd expects to be in /bin)
  # - CNI plugins → /opt/cni/bin/
  # Uses _bin_ok() to skip already-installed executables unless --force.
  # ----------------------------------------------------------------------------
  echo "--- [4/7] Installing worker binaries on ${node} ---"
  _remote_run "${node}" <<REMOTE
set -euo pipefail
FORCE="${FORCE}"

_bin_ok() {
  local bin="\$1" path="\$2"
  [[ -x "\${path}/\${bin}" ]] && "\${path}/\${bin}" --version >/dev/null 2>&1
}

# /usr/local/bin binaries
for bin in crictl kube-proxy kubelet runc; do
  if [[ "\${FORCE}" != "true" ]] && _bin_ok "\${bin}" /usr/local/bin; then
    echo "  \${bin} already installed — skipping."
  elif [[ -f ~/\${bin} ]]; then
    mv -f ~/\${bin} /usr/local/bin/
    chmod +x /usr/local/bin/\${bin}
    echo "  Installed: /usr/local/bin/\${bin}"
  elif [[ -x /usr/local/bin/\${bin} ]]; then
    echo "  \${bin} already at /usr/local/bin/ (no staged file) — skipping."
  else
    echo "  ERROR: \${bin} not found. Run copy-worker-files.sh first."
    exit 1
  fi
done

# kubectl (client tool for on-node debugging)
if [[ "\${FORCE}" != "true" ]] && [[ -x /usr/local/bin/kubectl ]]; then
  echo "  kubectl already installed — skipping."
elif [[ -f ~/kubectl ]]; then
  mv -f ~/kubectl /usr/local/bin/
  chmod +x /usr/local/bin/kubectl
  echo "  Installed: /usr/local/bin/kubectl"
fi

# /bin binaries (containerd suite)
for bin in containerd containerd-shim-runc-v2 containerd-stress; do
  if [[ "\${FORCE}" != "true" ]] && [[ -x /bin/\${bin} ]]; then
    echo "  \${bin} already installed — skipping."
  elif [[ -f ~/\${bin} ]]; then
    mv -f ~/\${bin} /bin/
    chmod +x /bin/\${bin}
    echo "  Installed: /bin/\${bin}"
  elif [[ -x /bin/\${bin} ]]; then
    echo "  \${bin} already at /bin/ (no staged file) — skipping."
  fi
done

# CNI plugins → /opt/cni/bin/
if [[ "\${FORCE}" != "true" ]] && ls /opt/cni/bin/* >/dev/null 2>&1; then
  echo "  CNI plugins already installed — skipping."
elif ls ~/cni-plugins/* >/dev/null 2>&1; then
  mv -f ~/cni-plugins/* /opt/cni/bin/
  chmod +x /opt/cni/bin/*
  echo "  Installed CNI plugins to /opt/cni/bin/"
else
  echo "  CNI plugins already in /opt/cni/bin/ (no staged files) — skipping."
fi
REMOTE

  # ----------------------------------------------------------------------------
  # STEP 5 — Configure CNI networking
  # Installs bridge and loopback CNI configs, loads br-netfilter kernel module
  # (required for iptables to see bridged traffic), and sets sysctl parameters
  # so iptables rules apply to CNI bridge traffic.
  # ----------------------------------------------------------------------------
  echo "--- [5/7] Configuring CNI networking on ${node} ---"
  _remote_run "${node}" <<REMOTE
set -euo pipefail
FORCE="${FORCE}"

# CNI network config files
for f in 10-bridge.conf 99-loopback.conf; do
  if [[ "\${FORCE}" != "true" ]] && [[ -f /etc/cni/net.d/\${f} ]]; then
    echo "  Already in place: /etc/cni/net.d/\${f} — skipping."
  elif [[ -f ~/\${f} ]]; then
    mv -f ~/\${f} /etc/cni/net.d/
    echo "  Placed: /etc/cni/net.d/\${f}"
  fi
done

# Load br-netfilter so iptables can process bridged packets
modprobe br-netfilter
grep -qxF 'br-netfilter' /etc/modules-load.d/modules.conf \
  || echo "br-netfilter" >> /etc/modules-load.d/modules.conf

# sysctl: enable iptables processing of bridge traffic
for param in net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables; do
  grep -qxF "\${param} = 1" /etc/sysctl.d/kubernetes.conf 2>/dev/null \
    || echo "\${param} = 1" >> /etc/sysctl.d/kubernetes.conf
done
sysctl -p /etc/sysctl.d/kubernetes.conf
REMOTE

  # ----------------------------------------------------------------------------
  # STEP 6 — Configure containerd, kubelet, and kube-proxy
  # Places config files and systemd unit files into their expected locations.
  # Each placement is skipped if the destination already exists (unless --force).
  # ----------------------------------------------------------------------------
  echo "--- [6/7] Configuring containerd, kubelet, and kube-proxy on ${node} ---"
  _remote_run "${node}" <<REMOTE
set -euo pipefail
FORCE="${FORCE}"

_place() {
  local src="\$1" dest="\$2"
  local name="\$(basename "\${src}")"
  if [[ "\${FORCE}" != "true" ]] && [[ -f "\${dest}" ]]; then
    echo "  Already in place: \${dest} — skipping."
  elif [[ -f "\${src}" ]]; then
    mv -f "\${src}" "\${dest}"
    echo "  Placed: \${dest}"
  elif [[ -f "\${dest}" ]]; then
    echo "  Already in place: \${dest} (no staged file) — skipping."
  else
    echo "  ERROR: \${name} not found in ~/ and not at \${dest}. Run copy-worker-files.sh first."
    exit 1
  fi
}

# containerd
mkdir -p /etc/containerd
_place ~/containerd-config.toml      /etc/containerd/config.toml
_place ~/containerd.service          /etc/systemd/system/containerd.service

# kubelet
_place ~/kubelet-config.yaml         /var/lib/kubelet/kubelet-config.yaml
_place ~/kubelet.service             /etc/systemd/system/kubelet.service

# kube-proxy
_place ~/kube-proxy-config.yaml      /var/lib/kube-proxy/kube-proxy-config.yaml
_place ~/kube-proxy.service          /etc/systemd/system/kube-proxy.service
REMOTE

  # ----------------------------------------------------------------------------
  # STEP 7 — Enable and start worker services
  # Reloads systemd to pick up new unit files, enables services for auto-start
  # on reboot, then starts (or restarts with --force) all three services.
  # Prints journal output on failure to aid diagnosis.
  # ----------------------------------------------------------------------------
  echo "--- [7/7] Starting worker services on ${node} ---"
  _remote_run "${node}" <<REMOTE
set -euo pipefail
FORCE="${FORCE}"

systemctl daemon-reload
systemctl enable containerd kubelet kube-proxy

for svc in containerd kubelet kube-proxy; do
  if [[ "\${FORCE}" == "true" ]]; then
    systemctl restart "\${svc}" || {
      echo "  ERROR: \${svc} failed to start. Journal:"
      journalctl -xeu "\${svc}" --no-pager | tail -30
      exit 1
    }
  elif systemctl is-active --quiet "\${svc}"; then
    echo "  \${svc} already running — skipping start."
  else
    systemctl start "\${svc}" || {
      echo "  ERROR: \${svc} failed to start. Journal:"
      journalctl -xeu "\${svc}" --no-pager | tail -30
      exit 1
    }
  fi
done
REMOTE

  echo "=== ${node} bootstrapped successfully ==="
  echo ""
done

echo "=== All worker nodes bootstrapped ==="
echo "Next: run ./scripts/09-workers/verify-workers.sh"
