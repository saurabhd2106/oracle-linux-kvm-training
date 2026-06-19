#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DD_NAME="setup"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

TOOLS=(vscode chrome docker terraform ansible kubectl graphviz)
ONLY_TOOLS=""

usage() {
  cat <<'EOF'
Usage:
  bash setup-dd/setup.sh [--only tool1,tool2]

Tools:
  vscode, chrome, docker, terraform, ansible, kubectl, graphviz

Examples:
  bash setup-dd/setup.sh
  bash setup-dd/setup.sh --only docker,terraform
  SKIP_CHROME=true bash setup-dd/setup.sh

Environment:
  SKIP_VSCODE=true      Skip VS Code
  SKIP_CHROME=true      Skip Chrome
  SKIP_DOCKER=true      Skip Docker
  SKIP_TERRAFORM=true   Skip Terraform
  SKIP_ANSIBLE=true     Skip Ansible
  SKIP_KUBECTL=true     Skip kubectl
  SKIP_GRAPHVIZ=true    Skip Graphviz
  KUBECTL_MINOR_VERSION Override kubectl repo version, e.g. v1.36
  SETUP_DD_USER         User to add to docker group, defaults to current user
EOF
}

is_known_tool() {
  local tool="$1"
  local known

  for known in "${TOOLS[@]}"; do
    if [[ "$known" == "$tool" ]]; then
      return 0
    fi
  done

  return 1
}

validate_only_tools() {
  local item
  local normalized

  if [[ -z "$ONLY_TOOLS" ]]; then
    return 0
  fi

  normalized="${ONLY_TOOLS//,/ }"
  for item in $normalized; do
    if ! is_known_tool "$item"; then
      fail "unknown tool in --only list: $item"
    fi
  done
}

should_run_tool() {
  local tool="$1"
  local upper
  local skip_var
  local skip_value

  if [[ -n "$ONLY_TOOLS" ]]; then
    case ",$ONLY_TOOLS," in
      *",$tool,"*) ;;
      *) return 1 ;;
    esac
  fi

  upper="$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')"
  skip_var="SKIP_${upper}"
  skip_value="${!skip_var:-false}"

  [[ "$skip_value" != "true" ]]
}

run_tool() {
  local tool="$1"
  local script="$SCRIPT_DIR/install-${tool}.sh"

  if should_run_tool "$tool"; then
    log "Running installer: $tool"
    bash "$script"
  else
    log "Skipping installer: $tool"
  fi
}

print_summary() {
  cat <<'EOF'

Installed version summary:
EOF
  printf '  VS Code:   %s\n' "$(print_command_version code --version)"
  printf '  Chrome:    %s\n' "$(print_command_version google-chrome --version)"
  printf '  Docker:    %s\n' "$(print_command_version docker --version)"
  printf '  Terraform: %s\n' "$(print_command_version terraform version)"
  printf '  Ansible:   %s\n' "$(print_command_version ansible --version)"
  printf '  kubectl:   %s\n' "$(print_command_version kubectl version --client)"
  printf '  Graphviz:  %s\n' "$(print_command_version dot -V)"

  cat <<'EOF'

If Docker was newly installed or your user was newly added to the docker group,
log out and back in, or run:

  newgrp docker
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --only)
      [[ "$#" -ge 2 ]] || fail "--only requires a comma-separated tool list"
      ONLY_TOOLS="$2"
      shift 2
      ;;
    --only=*)
      ONLY_TOOLS="${1#--only=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

ensure_apt
validate_only_tools

for tool in "${TOOLS[@]}"; do
  run_tool "$tool"
done

print_summary
