#!/usr/bin/env bash

# ==============================================================================
# KTHW UPGRADE — Step 2: Download new binaries
# Runs on: jumpbox/local machine
#
# Sources the target versions from versions.env (or uses env vars already set)
# and re-runs the install script with --force to download fresh binaries.
#
# Usage:
#   # Use versions from versions.env:
#   source scripts/14-upgrade/versions.env
#   ./scripts/14-upgrade/02-download-new-binaries.sh
#
#   # Or override a single version inline:
#   KUBERNETES_VERSION=v1.33.1 ./scripts/14-upgrade/02-download-new-binaries.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "=== Target versions ==="
echo "  KUBERNETES_VERSION : ${KUBERNETES_VERSION:-not set — will use default in install script}"
echo "  CRICTL_VERSION     : ${CRICTL_VERSION:-not set}"
echo "  CNI_PLUGINS_VERSION: ${CNI_PLUGINS_VERSION:-not set}"
echo "  CONTAINERD_VERSION : ${CONTAINERD_VERSION:-not set}"
echo "  ETCD_VERSION       : ${ETCD_VERSION:-not set}"
echo ""

# --force ensures all binaries are re-downloaded even if same-named files exist
# from the previous version (plain binaries like kubectl share the same filename
# across versions — without --force the old binary would be kept)
echo "=== Downloading new binaries (--force re-downloads all) ==="
"${ROOT_DIR}/scripts/02-jumpbox/install-cli-tools-macbook-m2.sh" --force

echo ""
echo "=== New binaries are ready in kthw-downloads/ ==="
echo "Next: run ./scripts/14-upgrade/03-upgrade-control-plane.sh"
