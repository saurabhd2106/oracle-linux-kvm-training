#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DD_NAME="install-kubectl"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

KUBECTL_MINOR_VERSION="${KUBECTL_MINOR_VERSION:-v1.36}"
KUBERNETES_REPO_URL="https://pkgs.k8s.io/core:/stable:/${KUBECTL_MINOR_VERSION}/deb/"

ensure_apt

if command -v kubectl >/dev/null 2>&1; then
  log "kubectl is already installed: $(kubectl version --client | sed -n '1p')"
  exit 0
fi

install_gpg_key \
  "${KUBERNETES_REPO_URL}Release.key" \
  "/etc/apt/keyrings/kubernetes-apt-keyring.gpg"

write_apt_source \
  "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${KUBERNETES_REPO_URL} /" \
  "/etc/apt/sources.list.d/kubernetes.list"

apt_install kubectl

log "kubectl installed successfully: $(kubectl version --client | sed -n '1p')"
