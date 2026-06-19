#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DD_NAME="install-terraform"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

ensure_apt

if command -v terraform >/dev/null 2>&1; then
  log "Terraform is already installed: $(terraform version | sed -n '1p')"
  exit 0
fi

install_gpg_key \
  "https://apt.releases.hashicorp.com/gpg" \
  "/etc/apt/keyrings/hashicorp-archive-keyring.gpg"

write_apt_source \
  "deb [arch=$(dpkg_arch) signed-by=/etc/apt/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(ubuntu_codename) main" \
  "/etc/apt/sources.list.d/hashicorp.list"

apt_install terraform

log "Terraform installed successfully: $(terraform version | sed -n '1p')"
