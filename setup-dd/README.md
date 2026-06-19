# Ubuntu Dev VM Setup Scripts

This folder contains modular scripts for setting up an Ubuntu desktop VM with:

- VS Code
- Google Chrome
- Docker Engine, Docker Buildx, and Docker Compose plugin
- Terraform
- Ansible
- kubectl
- Graphviz (`dot`)

The scripts are written for Ubuntu with `apt` and use official upstream package repositories where appropriate.

## Prerequisites

- Ubuntu 22.04 / 24.04 or newer
- `amd64` VM for Google Chrome
- A user with `sudo` access
- Internet access from the VM

## Run Everything

From the repository root:

```sh
bash setup-dd/setup.sh
```

The master script runs each installer in this order:

```text
vscode, chrome, docker, terraform, ansible, kubectl, graphviz
```

Each installer checks whether the tool is already installed before making changes.

## Install Only Some Tools

Use `--only` with a comma-separated list:

```sh
bash setup-dd/setup.sh --only docker,terraform,kubectl
```

Available tool names:

```text
vscode, chrome, docker, terraform, ansible, kubectl, graphviz
```

## Skip Tools

Use `SKIP_<TOOL>=true`:

```sh
SKIP_CHROME=true SKIP_VSCODE=true bash setup-dd/setup.sh
```

Supported skip variables:

```text
SKIP_VSCODE
SKIP_CHROME
SKIP_DOCKER
SKIP_TERRAFORM
SKIP_ANSIBLE
SKIP_KUBECTL
SKIP_GRAPHVIZ
```

## Run Individual Installers

Each installer can be run directly:

```sh
bash setup-dd/install-vscode.sh
bash setup-dd/install-chrome.sh
bash setup-dd/install-docker.sh
bash setup-dd/install-terraform.sh
bash setup-dd/install-ansible.sh
bash setup-dd/install-kubectl.sh
bash setup-dd/install-graphviz.sh
```

## Docker Without sudo

The Docker installer adds your user to the `docker` group:

```sh
sudo usermod -aG docker "$USER"
```

Group membership is not active in already-open shells. After the script finishes, log out and back in, or run:

```sh
newgrp docker
```

Then verify:

```sh
docker run hello-world
```

## kubectl Version

The kubectl installer uses the Kubernetes `pkgs.k8s.io` stable apt repository. By default it uses `v1.36`.

Override the Kubernetes minor version if needed:

```sh
KUBECTL_MINOR_VERSION=v1.35 bash setup-dd/install-kubectl.sh
```

## Verify Installation

Run these commands after setup:

```sh
code --version
google-chrome --version
docker --version
docker compose version
terraform version
ansible --version
kubectl version --client
dot -V
```

## Files

- `setup.sh`: master installer
- `lib/common.sh`: shared bash helpers
- `install-vscode.sh`: VS Code installer
- `install-chrome.sh`: Google Chrome installer
- `install-docker.sh`: Docker installer
- `install-terraform.sh`: Terraform installer
- `install-ansible.sh`: Ansible installer
- `install-kubectl.sh`: kubectl installer
- `install-graphviz.sh`: Graphviz / `dot` installer

## Safety Notes

- The scripts do not store credentials or secrets.
- Official signing keys are installed under `/etc/apt/keyrings`.
- Official apt source files are installed under `/etc/apt/sources.list.d`.
- Package installation uses `sudo apt-get install -y`.
