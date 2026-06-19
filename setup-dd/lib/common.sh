#!/usr/bin/env bash

if [[ "${SETUP_DD_COMMON_LOADED:-false}" == "true" ]]; then
  return 0
fi
SETUP_DD_COMMON_LOADED=true

SETUP_DD_NAME="${SETUP_DD_NAME:-setup-dd}"
APT_UPDATED="${APT_UPDATED:-false}"

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

log() {
  printf '[%s] %s\n' "$SETUP_DD_NAME" "$1"
}

warn() {
  printf '[%s] Warning: %s\n' "$SETUP_DD_NAME" "$1" >&2
}

fail() {
  printf '[%s] Error: %s\n' "$SETUP_DD_NAME" "$1" >&2
  exit 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "required command not found: $1"
  fi
}

run_sudo() {
  "${SUDO[@]}" "$@"
}

ensure_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    fail "this script is intended for Linux. Detected: $(uname -s)"
  fi
}

ensure_ubuntu() {
  ensure_linux

  if [[ ! -r /etc/os-release ]]; then
    fail "cannot read /etc/os-release to detect the Linux distribution"
  fi

  # shellcheck disable=SC1091
  . /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
    fail "this setup is intended for Ubuntu. Detected: ${PRETTY_NAME:-unknown}"
  fi
}

ensure_apt() {
  ensure_ubuntu
  require_command apt-get
  require_command dpkg
  require_command dpkg-query

  if [[ "${#SUDO[@]}" -gt 0 ]]; then
    require_command sudo
  fi
}

apt_update_once() {
  ensure_apt

  if [[ "$APT_UPDATED" == "true" ]]; then
    return 0
  fi

  log "Updating apt package indexes."
  run_sudo apt-get update
  APT_UPDATED=true
}

apt_install() {
  ensure_apt

  if [[ "$#" -eq 0 ]]; then
    return 0
  fi

  apt_update_once
  log "Installing packages: $*"
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

ensure_apt_prereqs() {
  apt_install ca-certificates curl gnupg
}

is_package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

dpkg_arch() {
  dpkg --print-architecture
}

ubuntu_codename() {
  # shellcheck disable=SC1091
  . /etc/os-release

  if [[ -n "${VERSION_CODENAME:-}" ]]; then
    printf '%s\n' "$VERSION_CODENAME"
    return 0
  fi

  require_command lsb_release
  lsb_release -cs
}

install_gpg_key() {
  local key_url="$1"
  local keyring_path="$2"

  ensure_apt_prereqs

  if [[ -s "$keyring_path" ]]; then
    log "GPG key already exists: $keyring_path"
    return 0
  fi

  local tmp_file
  tmp_file="$(mktemp)"

  log "Installing GPG key: $keyring_path"
  curl -fsSL "$key_url" | gpg --dearmor >"$tmp_file"
  run_sudo install -d -m 0755 "$(dirname "$keyring_path")"
  run_sudo install -m 0644 "$tmp_file" "$keyring_path"
  rm -f "$tmp_file"
}

write_apt_source() {
  local source_line="$1"
  local source_path="$2"
  local tmp_file

  if [[ -r "$source_path" ]] && grep -Fxq "$source_line" "$source_path"; then
    log "Apt source already configured: $source_path"
    return 0
  fi

  tmp_file="$(mktemp)"
  printf '%s\n' "$source_line" >"$tmp_file"

  log "Configuring apt source: $source_path"
  run_sudo install -d -m 0755 "$(dirname "$source_path")"
  run_sudo install -m 0644 "$tmp_file" "$source_path"
  rm -f "$tmp_file"

  APT_UPDATED=false
}

target_user() {
  printf '%s\n' "${SETUP_DD_USER:-${SUDO_USER:-${USER}}}"
}

print_command_version() {
  local command_name="$1"
  shift

  if command -v "$command_name" >/dev/null 2>&1; then
    "$command_name" "$@" 2>&1 | sed -n '1p'
  else
    printf '%s not found\n' "$command_name"
  fi
}
