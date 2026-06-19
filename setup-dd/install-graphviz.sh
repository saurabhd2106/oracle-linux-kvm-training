#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DD_NAME="install-graphviz"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

ensure_apt

if command -v dot >/dev/null 2>&1; then
  log "Graphviz is already installed: $(dot -V 2>&1)"
  exit 0
fi

apt_install graphviz

log "Graphviz installed successfully: $(dot -V 2>&1)"
