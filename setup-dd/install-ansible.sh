#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DD_NAME="install-ansible"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

ensure_apt

if command -v ansible >/dev/null 2>&1; then
  log "Ansible is already installed: $(ansible --version | sed -n '1p')"
  exit 0
fi

apt_install software-properties-common

if compgen -G "/etc/apt/sources.list.d/ansible-ubuntu-ansible-*.list" >/dev/null; then
  log "Ansible PPA is already configured."
else
  log "Adding Ansible PPA."
  if run_sudo add-apt-repository --yes --update ppa:ansible/ansible; then
    APT_UPDATED=true
  else
    warn "could not add Ansible PPA; falling back to Ubuntu's default ansible package"
    APT_UPDATED=false
  fi
fi

apt_install ansible

log "Ansible installed successfully: $(ansible --version | sed -n '1p')"
