# Ansible: configure the OLVM platform

One Ansible project that configures every machine provisioned by `../terraform`:

| Group | Role | What it does |
|-------|------|--------------|
| `nfs_server` | `nfs_server` | Format/mount the data volume, install NFS, export `/exports/olvm` (+ `/exports/olvm-iso` for the ISO domain), open NFS ports |
| `engine` | `olvm_engine` | Install and configure the OLVM 4.5 Engine via unattended `engine-setup` |
| `kvm_hosts` | `olvm_host_prep` | Prep Oracle Linux 9.6+ hosts so "Add Host" in OLVM succeeds |
| `engine` | `olvm_config` | Create the Data Center, Cluster, add the hosts and the NFS storage domain via the Engine API (runs locally) |

`site.yml` runs them in that order.

## Prerequisites

- Ansible on your workstation.
- Collections: `ansible-galaxy collection install -r requirements.yml`
  (`ansible.posix`, `community.general`).
- The Terraform stack applied, and the private key present at
  `../terraform/generated/<name_prefix>-<project_name>` (default
  `../terraform/generated/sau-olvm-platform`, referenced by `ansible.cfg`).

### Ansible version: the Engine runs Oracle Linux 8 (Python 3.6)

The Engine host is Oracle Linux 8, whose `/usr/bin/python3` is Python 3.6, and
its `dnf` module bindings only exist for that 3.6 platform-python. `ansible-core`
2.17+ dropped support for Python 3.6 targets (its modules use
`from __future__ import annotations`, which needs Python >= 3.7), so a newer
controller fails against the Engine with
`SyntaxError: future feature annotations is not defined`.

Use **`ansible-core >= 2.16, < 2.17`** to drive this project - it supports the
OL8 Engine (3.6) and the OL9 hosts (3.9) alike. A clean isolated setup:

```sh
python3 -m venv ~/.venvs/olvm-ansible
~/.venvs/olvm-ansible/bin/pip install 'ansible-core>=2.16,<2.17'
# The olvm_config role talks to the Engine API and needs the oVirt SDK in the
# same Python env as ansible-core:
~/.venvs/olvm-ansible/bin/pip install ovirt-engine-sdk-python
~/.venvs/olvm-ansible/bin/ansible-galaxy collection install -r requirements.yml
# then run everything below with ~/.venvs/olvm-ansible/bin/ansible[-playbook]
```

The OL9 KVM/NFS hosts also work with a newer `ansible-core`; only the OL8 Engine
requires the 2.16 line.

## Configure the inventory

```sh
cd ../terraform
terraform output ansible_inventory_hint
terraform output -raw nfs_private_ip

cd ../ansible
cp inventory/hosts.yml.example inventory/hosts.yml
# edit inventory/hosts.yml: set ansible_host on each host, target_hostname and
# host_address (the private IP the Engine uses to add the host) per KVM host,
# and nfs_server_address to the NFS server's private IP.
```

## Secrets (Engine admin password)

`olvm_admin_password` is required and stored encrypted with Ansible Vault in
[`inventory/group_vars/engine/vault.yml`](inventory/group_vars/engine/vault.yml).
Create a `.vault_pass` file in this directory containing the vault passphrase
(gitignored); `ansible.cfg` already points at it. If you are migrating from the
old `install-olvm` project, reuse the same passphrase you used there. To set a
fresh password:

```sh
echo 'YourVaultPassphrase' > .vault_pass
ansible-vault edit inventory/group_vars/engine/vault.yml   # set olvm_admin_password
```

## Engine SSH key for the KVM hosts

`engine-setup` generates the Engine's SSH key during the `engine` play, and the
`kvm_hosts` play (`olvm_host_prep`) derives the public key automatically on the
Engine host from its private key (`/etc/pki/ovirt-engine/keys/engine_id_rsa`, via
`ssh-keygen -y`, since engine-setup does not store a `.pub` file) and authorizes
it for root on each KVM host. As long as the Engine is in the inventory `engine`
group and the `engine` play has run, no manual copy step is needed.

To override the source (for example when running `kvm_hosts` against an Engine not
in this inventory), set `engine_ssh_public_key` in
[`group_vars/kvm_hosts.yml`](inventory/group_vars/kvm_hosts.yml) to the key string
or a path to a local file. You can grab the key with:

```sh
ssh -i ../terraform/generated/sau-olvm-platform opc@<engine_public_ip> \
    sudo ssh-keygen -y -f /etc/pki/ovirt-engine/keys/engine_id_rsa
```

## Run

```sh
ansible-galaxy collection install -r requirements.yml
ansible all -m ping

# full run (nfs -> engine -> kvm hosts)
ansible-playbook site.yml

# or one tier at a time
ansible-playbook site.yml --limit nfs_server
ansible-playbook site.yml --limit engine
ansible-playbook site.yml --limit kvm_hosts

# create the OLVM objects (DC, cluster, hosts, storage domain) via the API
ansible-playbook site.yml --limit engine --tags olvm_config
```

Individual steps within a role are taggable, e.g. `--tags step03`.

## The olvm_config role (Engine API)

The final play runs the `olvm_config` role locally (`connection: local`,
`become: false`) against the Engine's REST API and creates:

1. The **Data Center** (`olvm_datacenter_name`, default `olvm-lab-dc`). On the
   first run the role renames the built-in `Default` DC in place (matched by
   `olvm_datacenter_source_name`, default `Default`); later runs are idempotent.
2. The **Cluster** (`olvm_cluster_name`, default `olvm-lab-cluster`; renamed from
   `Default` the same way; set `olvm_cluster_cpu_type` if the Engine needs an
   explicit CPU family).
3. Each **KVM host** from the `kvm_hosts` group, added by its `host_address`
   (private IP) and authenticated with the Engine SSH key already authorized by
   `olvm_host_prep` (`public_key: true`). It waits for each host to reach `Up`.
4. The **NFS storage domain** (`olvm_storage_domain_name`, default `olvm-data`)
   at `<nfs_server_address>:<nfs_export_path>`, attached to the Data Center, plus
   (Phase 2) a dedicated **ISO domain** (`olvm_iso_domain_name`, default
   `olvm-iso`) at `<nfs_server_address>:<nfs_iso_export_path>` so install media
   is kept out of the data domain. Disable it with
   `olvm_configure_iso_domain: false`; run just this step with `--tags iso_domain`
   (or `step10`). The `nfs_server` role exports both paths.
5. The **logical networks** (`olvm_networks`): a dedicated VM network `olvm-vm`
   and a dedicated live-migration network `olvm-migration` (granted the cluster
   migration role so migration traffic does not saturate `ovirtmgmt`). The
   built-in `ovirtmgmt` management/display network is left untouched.
6. The **vNIC profiles** (`olvm_vnic_profiles`, default `olvm-vm`) that guest
   NICs attach to (used by `scripts/create-vm.yml`).
7. Optionally, **attaching** the non-management networks to a host NIC
   (`olvm_configure_host_networks`, default `false`; set
   `olvm_host_network_interface`). It is opt-in because on a single-NIC OCI lab
   an untested VLAN attachment can disrupt host connectivity; the logical
   networks and cluster roles are created regardless. Note `vlan_tag` defaults
   (100/200) only pass on a VLAN-aware fabric - set them to `null` for a flat
   cloud subnet.

Run just the networking steps with `--tags networks` (or `step07`/`step08`/`step09`).

It authenticates using the vaulted `olvm_admin_password` and
`insecure: true` by default (set `olvm_api_insecure: false` and
`olvm_api_ca_file` for production). All defaults live in
[`roles/olvm_config/defaults/main.yml`](roles/olvm_config/defaults/main.yml).

Because this build enables Keycloak, the REST API username is the full
`admin@ovirt@internalsso` (with the profile suffix) - not the `admin@ovirt` you
type in the Admin Portal. Using `admin@ovirt` for the API fails with "No valid
profile found in credentials". If Keycloak was declined during `engine-setup`
(legacy AAA), override `olvm_api_username: admin@internal`.

Day-2 operations (VMs, snapshots, live migration) and disk/ISO uploads are
standalone helpers under [`scripts/`](../scripts/README.md): `upload-disk.yml`
(uploads via the Engine's `upload_disk.py` / imageio backend, more reliable for
large files than the browser), `create-vm.yml`, `vm-snapshot.yml` and
`vm-migrate.yml` (pure Engine API playbooks that reuse this project's inventory
and vault).

Prefer the Admin Portal instead? The equivalent manual steps still work: Compute
> Hosts > New (by private IP) and Storage > Domains > New Domain
(`<nfs_private_ip>:/exports/olvm`).
