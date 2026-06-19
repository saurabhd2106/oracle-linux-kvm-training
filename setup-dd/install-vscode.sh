#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DD_NAME="install-vscode"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

ensure_apt

if command -v code >/dev/null 2>&1; then
  log "VS Code is already installed: $(code --version | sed -n '1p')"
  exit 0
fi

install_gpg_key \
  "https://packages.microsoft.com/keys/microsoft.asc" \
  "/etc/apt/keyrings/packages.microsoft.gpg"

write_apt_source \
  "deb [arch=$(dpkg_arch) signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
  "/etc/apt/sources.list.d/vscode.list"

apt_install code

log "VS Code installed successfully: $(code --version | sed -n '1p')"
