# Ansible: configure the OLVM platform

One Ansible project that configures every machine provisioned by `../terraform`:

| Group | Role | What it does |
|-------|------|--------------|
| `nfs_server` | `nfs_server` | Format/mount the data volume, install NFS, export `/exports/olvm`, open NFS ports |
| `engine` | `olvm_engine` | Install and configure the OLVM 4.5 Engine via unattended `engine-setup` |
| `kvm_hosts` | `olvm_host_prep` | Prep Oracle Linux 9.6+ hosts so "Add Host" in OLVM succeeds |

`site.yml` runs them in that order.

## Prerequisites

- Ansible on your workstation.
- Collections: `ansible-galaxy collection install -r requirements.yml`
  (`ansible.posix`, `community.general`).
- The Terraform stack applied, and the private key present at
  `../terraform/generated/<name_prefix>-<project_name>` (default
  `../terraform/generated/sau-olvm-platform`, referenced by `ansible.cfg`).

## Configure the inventory

```sh
cd ../terraform
terraform output ansible_inventory_hint
terraform output -raw nfs_private_ip

cd ../ansible
cp inventory/hosts.yml.example inventory/hosts.yml
# edit inventory/hosts.yml: set ansible_host on each host, target_hostname per
# KVM host, and nfs_server_address to the NFS server's private IP.
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

`engine-setup` generates the Engine's SSH key during the `engine` play. Before
running the `kvm_hosts` play, copy that public key into
[`group_vars/kvm_hosts.yml`](inventory/group_vars/kvm_hosts.yml) as
`engine_ssh_public_key` (string or local file path):

```sh
ssh -i ../terraform/generated/sau-olvm-platform opc@<engine_public_ip> \
    sudo cat /etc/pki/ovirt-engine/keys/engine_id_rsa.pub
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
```

Individual steps within a role are taggable, e.g. `--tags step03`.

## After the playbook (manual OLVM Portal steps)

1. **Add each KVM host**: Compute > Hosts > New, using the host's private IP.
2. **Add the NFS storage domain**: Storage > Domains > New Domain, NFS data
   domain with export path `<nfs_private_ip>:/exports/olvm`.
3. Trust the Engine CA certificate in your browser to upload ISOs.
