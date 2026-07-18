# Install the OLVM 4.5 Engine on an Oracle Linux 8 VM

Ansible project that installs and configures the **Oracle Linux Virtualization
Manager (OLVM) 4.5 standalone Engine** on the Oracle Linux 8 VM provisioned by
[`../linux-ol8`](../linux-ol8/). `engine-setup` runs fully unattended from a
templated OTOPI answer file.

The playbook runs five clearly labeled steps:

| Step | What it does |
|------|--------------|
| 01 | Preflight: assert Oracle Linux 8, warn on low RAM, set the Engine FQDN and an `/etc/hosts` entry, ensure `chronyd` |
| 02 | Configure repositories: install `oracle-ovirt-release-45-el8` and enable the required repos |
| 03 | Install `ovirt-engine` and refresh the `ovirt-engine-setup*` plugin packages |
| 04 | Render the answer file and run `engine-setup --config=... --accept-defaults` (idempotent) |
| 05 | Verify the `ovirt-engine` service and print the access URLs |

## Important: Oracle Linux 8 is required

The OLVM 4.5 Engine only runs on **Oracle Linux 8.8+**. The
[`../linux-ol8`](../linux-ol8/) stack provisions Oracle Linux **8** by default
(`oracle_linux_version = "8"`), so a fresh stack is ready to use as-is. To use a
different host, point `ansible_host` in your inventory at an existing Oracle
Linux 8 host.

Step 01 asserts OL8 and fails fast with a clear message on anything else.

## How to run this script?

- Get the VM public IP: `terraform output -raw instance_public_ip` (run from `../linux-ol8`).
- Copy the example inventory: `cp inventory/hosts.yml.example inventory/hosts.yml`.
- Edit `inventory/hosts.yml` and set `ansible_host` to the IP from the first step.
- Set the Engine FQDN/org and admin password (see below).
- Run the playbook: `ansible-playbook playbooks/install-olvm.yml`.

## Layout

```
install-olvm/
  ansible.cfg                       # inventory, role path, remote user, SSH key
  .vault_pass                       # vault passphrase (gitignored, create locally)
  inventory/
    hosts.yml.example               # copy to hosts.yml and set the VM public IP
    group_vars/olvm_hosts/vars.yml  # FQDN, org, repos, packages, feature toggles
    group_vars/olvm_hosts/vault.yml # Ansible Vault-encrypted admin password
  playbooks/install-olvm.yml        # single play -> olvm_engine role
  roles/olvm_engine/
    defaults/main.yml               # role defaults (used when running with --tags)
    handlers/main.yml               # restart ovirt-engine, reload firewalld
    templates/answer.txt.j2         # OTOPI answer file for unattended engine-setup
    tasks/
      main.yml                      # imports the five steps, each with tags
      01_preflight.yml
      02_repositories.yml
      03_install_engine.yml
      04_engine_setup.yml
      05_verify.yml
```

## Prerequisites

- Ansible installed on your workstation (`ansible --version`)
- An **Oracle Linux 8.8+** lab VM reachable over SSH (see the OL8 note above)
- The Terraform-generated private key at
  `../linux-ol8/generated/sau-linux-ol8` (default `ansible.cfg` path)
- At least 4 GB RAM (16 GB recommended) on the Engine host

## Configure the inventory

Get the VM public IP from the Terraform stack and drop it into your inventory:

```sh
cd ../linux-ol8
terraform output -raw instance_public_ip

cd ../install-olvm
cp inventory/hosts.yml.example inventory/hosts.yml
# edit inventory/hosts.yml and set ansible_host to the IP printed above
```

If your `name_prefix`/`project_name` differ, update `private_key_file` in
[`ansible.cfg`](ansible.cfg) to match `terraform output -raw ssh_private_key_path`.

## Set the FQDN and admin password

`olvm_engine_fqdn` and `olvm_pki_org` default to `olvm-engine.lab.local` /
`lab.local` in [`inventory/group_vars/olvm_hosts/vars.yml`](inventory/group_vars/olvm_hosts/vars.yml).
Change them there if you have a real DNS name.

`olvm_admin_password` is **required** (login is `admin@ovirt`) and is stored
encrypted with Ansible Vault in
[`inventory/group_vars/olvm_hosts/vault.yml`](inventory/group_vars/olvm_hosts/vault.yml),
so it auto-loads for the `olvm_hosts` group with no command-line flags.

The vault is unlocked non-interactively via a **vault password file**. Create
`.vault_pass` in this directory containing the vault passphrase (it is gitignored):

```sh
echo 'YourStrongPassword!' > .vault_pass    # the vault passphrase, not committed
```

[`ansible.cfg`](ansible.cfg) already points at it (`vault_password_file = .vault_pass`),
so `ansible-playbook` and `ansible-vault` commands find it automatically.

To view or change the encrypted admin password:

```sh
ansible-vault view inventory/group_vars/olvm_hosts/vault.yml
ansible-vault edit inventory/group_vars/olvm_hosts/vault.yml   # add/update olvm_admin_password
```

`olvm_allow_weak_password: true` (default) lets simple training passwords through;
set it to `false` for production-strength passwords.

## Run

Confirm connectivity, then run the full playbook:

```sh
ansible -m ping olvm_hosts
ansible-playbook playbooks/install-olvm.yml
```

Run a single step using its tag (`step01` .. `step05`):

```sh
ansible-playbook playbooks/install-olvm.yml --tags step02
```

Preview the task/step list without connecting:

```sh
ansible-playbook playbooks/install-olvm.yml --list-tasks
```

## Post-install URLs

Once the run finishes, reach the Engine from a machine that can resolve the FQDN
(add a matching `/etc/hosts` entry pointing the FQDN at the VM public IP if needed):

| Application | URL | Username |
|-------------|-----|----------|
| Administration Portal | `https://<fqdn>/ovirt-engine/webadmin` | `admin@ovirt` |
| VM Portal | `https://<fqdn>/ovirt-engine/web-ui` | `admin@ovirt` |
| Grafana Monitoring | `https://<fqdn>/ovirt-engine-grafana/` | `admin` |
| Keycloak Admin Console | `https://<fqdn>/ovirt-engine-auth/admin` | `admin` |

## Manual follow-ups (out of scope for this playbook)

After the Engine is up, complete the environment from the Administration Portal:

- **Add a KVM host** under Compute > Hosts (a separate Oracle Linux KVM host).
- **Add a storage domain** (for example an NFS export) under Storage > Domains so
  the default Data Center moves to the `Up` state.
- **Trust the Engine CA certificate** in your browser to upload ISO images.

## Notes

- Targets the OLVM 4.5 standalone Engine (Manager only), not a self-hosted engine.
- The playbook is idempotent: `engine-setup` is skipped when
  `/etc/ovirt-engine-setup.conf.d/20-setup-ovirt-post.conf` already exists, and
  verification tasks use `changed_when: false`.
- The rendered answer file (which contains the admin password) is written to
  `/root/answer.txt` with mode `0600` and removed at the end of the run.
