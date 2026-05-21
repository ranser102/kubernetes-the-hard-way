#!/usr/bin/env bash

# ==============================================================================
# KTHW COMPUTE RESOURCE SSH CONFIGURATION
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KTHW_ZONE="${KTHW_ZONE:-$(gcloud config get-value compute/zone 2>/dev/null)}"
SSH_KEY_PATH="${KTHW_SSH_KEY_PATH:-${HOME}/.ssh/google_compute_engine}"
SSH_USER="${KTHW_SSH_USER:-$(whoami)}"

MACHINES_FILE="${ROOT_DIR}/machines.txt"
LOCAL_HOSTS_FILE="${ROOT_DIR}/hosts"
REMOTE_HOSTS_FILE="${ROOT_DIR}/hosts.internal"
LOCAL_ETC_HOSTS="${KTHW_LOCAL_ETC_HOSTS:-/etc/hosts}"

GCP_INSTANCES=(server node-0 node-1)
CLUSTER_HOSTS=(server node-0 node-1)
CLUSTER_FQDNS=(server.kubernetes.local node-0.kubernetes.local node-1.kubernetes.local)
POD_SUBNETS=("" "10.200.0.0/24" "10.200.1.0/24")

if [[ -z "${KTHW_ZONE}" || "${KTHW_ZONE}" == "(unset)" ]]; then
  echo "CRITICAL: compute/zone is not configured. Run scripts/01-prereq/init01.sh first."
  exit 1
fi

get_instance_value() {
  local instance="$1"
  local field="$2"

  gcloud compute instances describe "${instance}" \
    --zone "${KTHW_ZONE}" \
    --format="value(${field})"
}

replace_hosts_block() {
  local target_file="$1"
  local source_file="$2"
  local temp_file

  temp_file="$(mktemp)"

  if [[ -f "${target_file}" ]]; then
    awk '
      $0 == "# BEGIN Kubernetes The Hard Way" { skip = 1; next }
      $0 == "# END Kubernetes The Hard Way" { skip = 0; next }
      skip != 1 { print }
    ' "${target_file}" > "${temp_file}"
  fi

  {
    echo "# BEGIN Kubernetes The Hard Way"
    sed '/^$/d' "${source_file}"
    echo "# END Kubernetes The Hard Way"
  } >> "${temp_file}"

  if [[ "${target_file}" == "/etc/hosts" ]]; then
    sudo install -m 0644 "${temp_file}" "${target_file}"
  else
    install -m 0644 "${temp_file}" "${target_file}"
  fi
  rm -f "${temp_file}"
}

echo "=== [1/6] Discovering provisioned GCP instances ==="
external_ips=()
internal_ips=()

for instance in "${GCP_INSTANCES[@]}"; do
  internal_ip="$(get_instance_value "${instance}" "networkInterfaces[0].networkIP")"
  external_ip="$(get_instance_value "${instance}" "networkInterfaces[0].accessConfigs[0].natIP")"

  if [[ -z "${internal_ip}" || -z "${external_ip}" ]]; then
    echo "CRITICAL: ${instance} must have both internal and external IP addresses."
    exit 1
  fi

  internal_ips+=("${internal_ip}")
  external_ips+=("${external_ip}")
done

echo "=== [2/6] Writing compute resource machine files ==="
: > "${MACHINES_FILE}"
: > "${LOCAL_HOSTS_FILE}"
: > "${REMOTE_HOSTS_FILE}"

for i in "${!GCP_INSTANCES[@]}"; do
  if [[ -n "${POD_SUBNETS[$i]}" ]]; then
    printf "%s %s %s %s\n" \
      "${external_ips[$i]}" "${CLUSTER_FQDNS[$i]}" "${CLUSTER_HOSTS[$i]}" "${POD_SUBNETS[$i]}" \
      >> "${MACHINES_FILE}"
  else
    printf "%s %s %s\n" \
      "${external_ips[$i]}" "${CLUSTER_FQDNS[$i]}" "${CLUSTER_HOSTS[$i]}" \
      >> "${MACHINES_FILE}"
  fi

  printf "%s %s %s\n" \
    "${external_ips[$i]}" "${CLUSTER_FQDNS[$i]}" "${CLUSTER_HOSTS[$i]}" \
    >> "${LOCAL_HOSTS_FILE}"

  printf "%s %s %s\n" \
    "${internal_ips[$i]}" "${CLUSTER_FQDNS[$i]}" "${CLUSTER_HOSTS[$i]}" \
    >> "${REMOTE_HOSTS_FILE}"
done

echo "=== [3/6] Ensuring local SSH key exists ==="
if [[ ! -f "${SSH_KEY_PATH}" ]]; then
  ssh-keygen -t ed25519 -N "" -f "${SSH_KEY_PATH}" -C "kthw"
fi

if [[ ! -f "${SSH_KEY_PATH}.pub" ]]; then
  ssh-keygen -y -f "${SSH_KEY_PATH}" > "${SSH_KEY_PATH}.pub"
fi

REMOTE_CONFIG_SCRIPT="$(mktemp)"
trap 'rm -f "${REMOTE_CONFIG_SCRIPT}"' EXIT

cat > "${REMOTE_CONFIG_SCRIPT}" <<'REMOTE_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

host="$1"
fqdn="$2"

hostnamectl set-hostname "${host}"
if grep -q '^127.0.1.1' /etc/hosts; then
  sed -i "s/^127.0.1.1.*/127.0.1.1\t${fqdn} ${host}/" /etc/hosts
fi

mkdir -p /root/.ssh
touch /root/.ssh/authorized_keys
grep -qxF -f /tmp/kthw-root.pub /root/.ssh/authorized_keys \
  || cat /tmp/kthw-root.pub >> /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

awk '
  $0 == "# BEGIN Kubernetes The Hard Way" { skip = 1; next }
  $0 == "# END Kubernetes The Hard Way" { skip = 0; next }
  skip != 1 { print }
' /etc/hosts > /tmp/hosts.kthw

{
  echo "# BEGIN Kubernetes The Hard Way"
  sed '/^$/d' /tmp/kthw-hosts
  echo "# END Kubernetes The Hard Way"
} >> /tmp/hosts.kthw

install -m 0644 /tmp/hosts.kthw /etc/hosts
REMOTE_SCRIPT

echo "=== [4/6] Configuring remote hostnames, root SSH, and internal host lookup ==="
for i in "${!GCP_INSTANCES[@]}"; do
  instance="${GCP_INSTANCES[$i]}"
  host="${CLUSTER_HOSTS[$i]}"
  fqdn="${CLUSTER_FQDNS[$i]}"

  gcloud compute scp \
    "${REMOTE_HOSTS_FILE}" \
    "${SSH_KEY_PATH}.pub" \
    "${REMOTE_CONFIG_SCRIPT}" \
    "${instance}:/tmp/" \
    --zone "${KTHW_ZONE}" \
    --quiet

  gcloud compute ssh "${instance}" \
    --zone "${KTHW_ZONE}" \
    --quiet \
    --command "sudo cp /tmp/$(basename "${REMOTE_HOSTS_FILE}") /tmp/kthw-hosts && \
      sudo cp /tmp/$(basename "${SSH_KEY_PATH}.pub") /tmp/kthw-root.pub && \
      sudo bash /tmp/$(basename "${REMOTE_CONFIG_SCRIPT}") '${host}' '${fqdn}'"
done

echo "=== [5/6] Updating local host lookup with external IPs ==="
replace_hosts_block "${LOCAL_ETC_HOSTS}" "${LOCAL_HOSTS_FILE}"

if [[ "${LOCAL_ETC_HOSTS}" == "/etc/hosts" ]]; then
  echo "=== [6/6] Validating regular SSH with cluster hostnames ==="
  for host in "${CLUSTER_HOSTS[@]}"; do
    ssh -i "${SSH_KEY_PATH}" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 \
      "${SSH_USER}@${host}" hostname
  done
else
  echo "=== Skipping regular SSH validation; ${LOCAL_ETC_HOSTS} is not /etc/hosts ==="
fi

echo "=== Compute resource SSH settings are configured ==="
echo "Generated: ${MACHINES_FILE}"
echo "Generated: ${LOCAL_HOSTS_FILE}"
echo "Generated: ${REMOTE_HOSTS_FILE}"
echo "Next: ./scripts/03-compute-resources/restart-sshd.sh"
