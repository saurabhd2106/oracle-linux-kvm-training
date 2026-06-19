#!/usr/bin/env bash
set -euo pipefail

INSTALLER_URL="https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh"
INSTALLER_ARGS="${OCI_CLI_INSTALLER_ARGS:---accept-all-defaults}"
INSTALL_DIR="${OCI_CLI_INSTALL_DIR:-$HOME/lib/oracle-cli}"
EXEC_DIR="${OCI_CLI_EXEC_DIR:-$HOME/bin}"
REMOVE_EXISTING="${OCI_CLI_REMOVE_EXISTING:-false}"

log() {
  printf '[oci-cli-linux] %s\n' "$1"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Error: required command not found: %s\n' "$1" >&2
    exit 1
  fi
}

if [[ "$(uname -s)" != "Linux" ]]; then
  printf 'Error: this script is intended for Linux. Detected: %s\n' "$(uname -s)" >&2
  exit 1
fi

require_command bash
require_command curl
require_command python3

if command -v oci >/dev/null 2>&1; then
  log "OCI CLI is already installed: $(oci --version)"
  exit 0
fi

if [[ -x "$EXEC_DIR/oci" ]]; then
  log "OCI CLI is already installed at $EXEC_DIR/oci: $("$EXEC_DIR/oci" --version)"
  cat <<'EOF'

Your current shell cannot find `oci` because the install directory is not on PATH.

Run this for the current terminal:

  export PATH="$HOME/bin:$PATH"

Then run:

  oci setup config
EOF
  exit 0
fi

if [[ -d "$INSTALL_DIR" ]]; then
  if [[ "$REMOVE_EXISTING" == "true" ]]; then
    log "Removing existing OCI CLI install directory: $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
  else
    cat <<EOF >&2
Error: existing OCI CLI install directory found:

  $INSTALL_DIR

Oracle's installer refuses to overwrite this directory.

If this is a failed or old OCI CLI install, re-run with:

  OCI_CLI_REMOVE_EXISTING=true ./install-oci-cli-linux.sh

Or remove it manually:

  rm -rf "$INSTALL_DIR"
  ./install-oci-cli-linux.sh

No files were changed by this script.
EOF
    exit 1
  fi
fi

installer_file="$(mktemp)"
trap 'rm -f "$installer_file"' EXIT

log "Downloading Oracle's official OCI CLI installer."
curl -fsSL "$INSTALLER_URL" -o "$installer_file"

log "Running installer with arguments: $INSTALLER_ARGS"
bash "$installer_file" $INSTALLER_ARGS

export PATH="$HOME/bin:$PATH"

if command -v oci >/dev/null 2>&1; then
  log "OCI CLI installed successfully: $(oci --version)"
  cat <<'EOF'

If your current terminal still cannot find `oci`, run:

  export PATH="$HOME/bin:$PATH"

To make that permanent for bash:

  echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
  exec -l "$SHELL"
EOF
else
  cat <<'EOF'
OCI CLI installation finished, but `oci` was not found on PATH.

Add this line to your shell profile, then open a new terminal:

  export PATH="$HOME/bin:$PATH"
EOF
fi

cat <<'EOF'

Next step:

  oci setup config

This configures your tenancy OCID, user OCID, region, API key, and fingerprint.
EOF
