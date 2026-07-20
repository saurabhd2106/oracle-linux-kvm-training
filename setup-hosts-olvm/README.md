# Prepare an Oracle Linux 9.6+ host for OLVM 4.5

Ansible project that prepares a fresh **Oracle Linux 9.6+** host so that running
**Add Host** in the **OLVM 4.5 Administration Portal** succeeds on the first
attempt, with no manual intervention. It only preps the KVM host side.

The OLVM Engine is assumed to already exist; installing or configuring the Engine
is done by the sibling [`../install-olvm`](../install-olvm/) project and is out of
scope here.

## What this does

The `olvm_host_prep` role runs seven clearly labeled, individually taggable steps:

| Step | Tag | What it does |
|------|-----|--------------|
| 01 | `step01` | Assert Oracle Linux 9.6+; fail loudly if a general KVM/libvirt stack is already installed |
| 02 | `step02` | Set the FQDN; verify DNS (fall back to `/etc/hosts`); confirm `/dev/kvm` + VT-x/AMD-V |
| 03 | `step03` | Install the OLVM release package; enable required repos; disable conflicting OCI repos |
| 04 | `step04` | Locate and run the OLVM pre-check script; treat `FAIL` as fatal (except the known cloud package-count false-positive), surface `WARN` |
| 05 | `step05` | Open the OLVM ports in local `firewalld` (if active); emit a port report for the cloud security list |
| 06 | `step06` | Authorize the Engine's SSH public key for `root` (key-based only) |
| 07 | `step07` | Print a scannable readiness summary |

## What this deliberately does NOT do

- **Does not install any KVM/libvirt/virtualization packages or groups.** OLVM
  installs its own version-pinned `vdsm`/`libvirt`/`qemu-kvm` stack when the host
  is added through the UI. Pre-installing anything from `ol9_appstream` or a
  "Virtualization Host" group causes unresolvable dependency conflicts
  (e.g. `libvirt-lock-sanlock` version mismatches) that are hard to undo.
- Does not install `ovirt-hosted-engine-setup` / `ovirt-engine-appliance`.
- Does not install or configure the OLVM Engine.
- Does not add the host to OLVM (that stays a manual portal step).
- Does not modify cloud security lists / NSGs (Terraform-managed, separate).
- Does not configure Power Management (cloud hosts have no IPMI/iLO).

## Prerequisites

- Ansible on your workstation (`ansible --version`).
- The `ansible.posix` collection (provides the `firewalld` and `authorized_key`
  modules): `ansible-galaxy collection install ansible.posix`.
- A reachable **Oracle Linux 9.6+** host, SSH-accessible as a sudo-capable user
  (e.g. `opc`), not root directly.

## Configure

```sh
cp inventory/hosts.yml.example inventory/hosts.yml
# edit inventory/hosts.yml: set ansible_host and target_hostname per host
```

Set the required variables in
[`group_vars/kvm_hosts.yml`](group_vars/kvm_hosts.yml):

- `engine_ssh_public_key` (**required**) - the OLVM Engine's SSH public key,
  either the literal key string or a path to a local file containing it. Do not
  commit a real key to a shared repo.
- `target_hostname` is normally set per host in the inventory.

Other tunables (all have defaults in
[`roles/olvm_host_prep/defaults/main.yml`](roles/olvm_host_prep/defaults/main.yml)):
`olvm_release_package`, `olvm_min_ol_version`, `olvm_required_repos`,
`repos_to_disable`, `extra_repos_to_disable`, `firewall_ports`.

## Run

```sh
ansible -m ping kvm_hosts
ansible-playbook site.yml
```

Run a single step by tag (`step01` .. `step07`):

```sh
ansible-playbook site.yml --tags step03
```

Preview the task list without connecting:

```sh
ansible-playbook site.yml --list-tasks
```

The playbook is idempotent: a second run produces no changes.

## Testing against a disposable host first

Running this against the *wrong* host is the main risk: a host that already has a
general KVM/libvirt stack (step 01 guards against exactly this) can be left in a
state that is very hard to recover on shared infrastructure. Always validate on a
throwaway instance first.

1. Provision a **disposable OCI instance** on Oracle Linux 9.6+ (a shape that
   exposes hardware virtualization). Do not reuse a real training host.
2. Point `inventory/hosts.yml` at it and run a **dry run** first:

   ```sh
   ansible-playbook site.yml --check --diff
   ```

   Most steps are `--check` friendly (validation, `lineinfile`, `file`,
   `firewalld`, `authorized_key`). Package installs and the pre-check script are
   reported but not fully simulated in check mode.
3. Run for real against the disposable host, confirm the step 07 summary is
   clean, and only then point the inventory at a real training host.

## After this playbook

Ensure the cloud security list / Terraform config allows the ports listed in the
step 05 report (managed separately), then go to the OLVM Administration Portal and
run **Compute > Hosts > Add Host** against this host.
