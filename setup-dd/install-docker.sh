#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DD_NAME="install-docker"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

ensure_apt

docker_user="$(target_user)"

install_gpg_key \
  "https://download.docker.com/linux/ubuntu/gpg" \
  "/etc/apt/keyrings/docker.gpg"

write_apt_source \
  "deb [arch=$(dpkg_arch) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(ubuntu_codename) stable" \
  "/etc/apt/sources.list.d/docker.list"

if command -v docker >/dev/null 2>&1; then
  log "Docker is already installed: $(docker --version)"
else
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  log "Docker installed successfully: $(docker --version)"
fi

run_sudo groupadd -f docker

if id -nG "$docker_user" | tr ' ' '\n' | grep -Fxq docker; then
  log "User '$docker_user' is already in the docker group."
else
  log "Adding user '$docker_user' to the docker group."
  run_sudo usermod -aG docker "$docker_user"
  cat <<EOF

Docker group membership has been updated for '$docker_user'.
Log out and back in, or run this in a new shell, before using Docker without sudo:

  newgrp docker

EOF
fi

if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files docker.service >/dev/null 2>&1; then
  log "Enabling and starting the Docker service."
  run_sudo systemctl enable --now docker || warn "could not enable/start docker.service; start it manually if needed"
fi

log "Verify Docker after group refresh with: docker run hello-world"
