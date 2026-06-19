#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DD_NAME="install-chrome"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

ensure_apt

if [[ "$(dpkg_arch)" != "amd64" ]]; then
  fail "Google Chrome's apt package is available for amd64 only. Detected: $(dpkg_arch)"
fi

if command -v google-chrome >/dev/null 2>&1; then
  log "Chrome is already installed: $(google-chrome --version)"
  exit 0
fi

install_gpg_key \
  "https://dl.google.com/linux/linux_signing_key.pub" \
  "/etc/apt/keyrings/google-linux-signing-key.gpg"

write_apt_source \
  "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-linux-signing-key.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
  "/etc/apt/sources.list.d/google-chrome.list"

apt_install google-chrome-stable

log "Chrome installed successfully: $(google-chrome --version)"
