# Install KVM on the Oracle Linux 9 Lab VM

Ansible project that installs and validates the KVM/libvirt virtualization stack
on the Oracle Linux 9 VM provisioned by [`../terraform-linux-day1`](../terraform-linux-day1/).

The playbook runs five clearly labeled steps:

| Step | What it does |
|------|--------------|
| 01 | Verify CPU virtualization extensions (`vmx`/`svm`) and nested-virt support |
| 02 | Install the `Virtualization Host` group plus `virt-install` and `virt-viewer` |
| 03 | Start and enable `libvirtd`; confirm with `systemctl status libvirtd` |
| 04 | Run `virsh list --all` and `virsh net-list --all` for a clean baseline |
| 05 | Add the training user to the `libvirt` group; confirm passwordless `virsh` |

## How to run this script?

- Get the VM public IP: `terraform output -raw instance_public_ip` (run from `../terraform-linux-day1`).
- Copy the example inventory: `cp inventory/hosts.yml.example inventory/hosts.yml`.
- Edit `inventory/hosts.yml` and set `ansible_host` to the IP from the first step.
- Run the playbook: `ansible-playbook playbooks/install-kvm.yml`.

## Layout

```
install-kvm/
  ansible.cfg                       # inventory, role path, remote user, SSH key
  inventory/
    hosts.yml.example               # copy to hosts.yml and set the VM public IP
    group_vars/kvm_hosts.yml        # training user, packages, service/group names
  playbooks/install-kvm.yml         # single play -> kvm_host role
  roles/kvm_host/
    defaults/main.yml               # role defaults (used when running with --tags)
    handlers/main.yml
    tasks/
      main.yml                      # imports the five steps, each with tags
      01_verify_cpu.yml
      02_install_packages.yml
      03_enable_libvirtd.yml
      04_baseline_virsh.yml
      05_libvirt_group.yml
```

## Prerequisites

- Ansible installed on your workstation (`ansible --version`)
- The lab VM deployed via `terraform-linux-day1`, reachable over SSH
- The Terraform-generated private key at
  `../terraform-linux-day1/generated/sau-linux-day1` (default `ansible.cfg` path)

## Configure the inventory

Get the VM public IP from the Terraform stack and drop it into your inventory:

```sh
cd ../terraform-linux-day1
terraform output -raw instance_public_ip

cd ../install-kvm
cp inventory/hosts.yml.example inventory/hosts.yml
# edit inventory/hosts.yml and set ansible_host to the IP printed above
```

If your `name_prefix`/`project_name` differ, update `private_key_file` in
[`ansible.cfg`](ansible.cfg) to match `terraform output -raw ssh_private_key_path`.

## Run

Confirm connectivity, then run the full playbook:

```sh
ansible -m ping kvm_hosts
ansible-playbook playbooks/install-kvm.yml
```

Run a single step using its tag (`step01` .. `step05`):

```sh
ansible-playbook playbooks/install-kvm.yml --tags step03
```

Preview the task/step list without connecting:

```sh
ansible-playbook playbooks/install-kvm.yml --list-tasks
```

## virt-manager GUI (optional)

The lab VM is headless, so the `virt-manager` GUI is launched from your
workstation over SSH X11 forwarding. Run this after the main `install-kvm.yml`
playbook (it needs KVM/libvirt already installed).

Prerequisite: an X server on your workstation. On macOS, install XQuartz and log
out/in once so `ssh -X` works:

```sh
brew install --cask xquartz
```

Install virt-manager and enable X11 forwarding on the VM:

```sh
ansible-playbook playbooks/install-virt-manager.yml
```

Launch the GUI over an X11-forwarded SSH session:

```sh
ssh -X -i ../terraform-linux-day1/generated/sau-linux-day1 opc@<public-ip> virt-manager
```

## Notes

- Targets the Oracle Linux 9 **default KVM stack** (the `Virtualization Host`
  dnf group), which is available from `ol9_appstream` with no extra repos.
- Step 05 verifies unprivileged access with `sg libvirt -c 'virsh ... list --all'`
  so it works within the same connection. Existing SSH sessions for the training
  user still need a fresh login before the new group membership applies to them.
- The playbook is idempotent: verification tasks use `changed_when: false`, and
  only `dnf`, `systemd`, `user`, and `group` tasks report changes.
