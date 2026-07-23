# Oracle Linux training

A hands-on training monorepo for Oracle Linux on Oracle Cloud Infrastructure (OCI).
It covers provisioning VMs with Terraform, installing KVM/libvirt, deploying guest
VMs from golden images with kcli, bootstrapping an Ubuntu desktop/dev VM, installing
the OCI CLI, and standing up a full Oracle Linux Virtualization Manager (OLVM) 4.5
lab with the merged `olvm-platform` stack.

Each project has its own README with full details and layout. This root README is an
index and quick-start; follow the per-project README for anything beyond the minimal
commands below.

## Learning paths

- Day-1 KVM lab: [`terraform-linux-day1`](terraform-linux-day1/) -> [`install-kvm`](install-kvm/) -> [`templates-kvm`](templates-kvm/)
- Workstation tooling: [`setup-dd`](setup-dd/) and [`install-oci-cli`](install-oci-cli/)
- Full OLVM 4.5 lab: [`olvm-platform`](olvm-platform/) (terraform -> ansible -> optional day-2 scripts)
- Docker teaching apps: [`sample-apps`](sample-apps/) (single-tier → two-tier → three-tier)

## Projects

| Project | Purpose | Details |
|---------|---------|---------|
| [`terraform-linux-day1`](terraform-linux-day1/) | OCI Terraform stack that provisions one or more Oracle Linux VMs with shared networking and per-VM data volumes | [README](terraform-linux-day1/README.md) |
| [`install-kvm`](install-kvm/) | Ansible project that installs and validates the KVM/libvirt stack on the day-1 lab VM | [README](install-kvm/README.md) |
| [`templates-kvm`](templates-kvm/) | Deploy N identical OL9 guest VMs from a golden image on the KVM host using kcli | [README](templates-kvm/README.md) |
| [`setup-dd`](setup-dd/) | Modular scripts to set up an Ubuntu desktop/dev VM (VS Code, Chrome, Docker, Terraform, Ansible, kubectl, Graphviz) | [README](setup-dd/README.md) |
| [`install-oci-cli`](install-oci-cli/) | OS-specific installers for the OCI CLI (Linux, macOS, Windows) | [README](install-oci-cli/README.md) |
| [`olvm-platform`](olvm-platform/) | Merged end-to-end OLVM 4.5 lab: Terraform infrastructure + Ansible configuration + day-2 helper scripts | [README](olvm-platform/README.md) |
| [`sample-apps`](sample-apps/) | Docker teaching sample apps (Java, Node, Python, two-tier, three-tier) with Dockerfiles and Compose labs | [README](sample-apps/README.md) |

## Prerequisites

- Terraform `1.5.0` or newer for the Terraform projects
- Ansible on your workstation for the Ansible projects
- An OCI tenancy with user/compartment OCIDs and an API signing key configured for the Terraform user
- SSH access to the provisioned VMs (Terraform generates a key pair under each stack's `generated/`)
- The OLVM day-2 scripts additionally need `ansible-core >= 2.16,<2.17` with `ovirt-engine-sdk-python` installed (see [`olvm-platform/ansible/README.md`](olvm-platform/ansible/README.md))

## Quick start

### terraform-linux-day1

```sh
cd terraform-linux-day1
cp terraform.tfvars.example terraform.tfvars   # fill in OCI credentials
terraform init
terraform apply
```

Full details: [`terraform-linux-day1/README.md`](terraform-linux-day1/README.md).

### install-kvm

```sh
cd terraform-linux-day1
terraform output -raw instance_public_ip

cd ../install-kvm
cp inventory/hosts.yml.example inventory/hosts.yml   # set ansible_host to the IP above
ansible-playbook playbooks/install-kvm.yml
```

Full details: [`install-kvm/README.md`](install-kvm/README.md).

### templates-kvm

Run on the KVM host as `opc`:

```sh
scp -i ../terraform-linux-day1/generated/sau-linux-day1 -r ../templates-kvm opc@<public-ip>:~/
ssh -i ../terraform-linux-day1/generated/sau-linux-day1 opc@<public-ip>
cd ~/templates-kvm
./bootstrap.sh                       # install kcli + download the golden ol9 image (once)
kcli create plan -f kcli_plan.yml    # clone vm_count guests
```

Full details: [`templates-kvm/README.md`](templates-kvm/README.md).

### install-oci-cli

Run the script for your OS from the repository root:

```sh
bash install-oci-cli/install-oci-cli-linux.sh     # Linux
bash install-oci-cli/install-oci-cli-macos.sh     # macOS
# Windows: install-oci-cli/install-oci-cli-windows.ps1 (PowerShell)
```

Full details: [`install-oci-cli/README.md`](install-oci-cli/README.md).

### setup-dd

From the repository root, on the target Ubuntu VM:

```sh
bash setup-dd/setup.sh
```

Full details: [`setup-dd/README.md`](setup-dd/README.md).

### olvm-platform

```sh
cd olvm-platform/terraform
cp terraform.tfvars.example terraform.tfvars   # fill in OCI credentials
terraform init
terraform apply

cd ../ansible
cp inventory/hosts.yml.example inventory/hosts.yml   # set ansible_host / private IPs per VM
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml
```

Vault setup, collection requirements, and the optional day-2 `scripts/` are documented in
[`olvm-platform/README.md`](olvm-platform/README.md).

## Merged and removed projects

The `olvm-platform` stack merges three previously separate projects, which are no longer
present as standalone folders: `linux-ol8` (Terraform OL8 Engine VM), `install-olvm`
(Ansible Engine install), and `setup-hosts-olvm` (Ansible KVM host prep). See the merge
table in [`olvm-platform/README.md`](olvm-platform/README.md) for where each one lives now.
