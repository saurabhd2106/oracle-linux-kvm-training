# scripts

Optional, standalone helpers for the OLVM platform. They reuse the main
project's inventory, vault and SSH key but are intentionally **not** part of
`site.yml`.

| Helper | Purpose |
|--------|---------|
| `upload-disk.yml` | Upload a disk image / ISO to a storage domain (runs on the Engine) |
| `create-vm.yml` | Create a VM from Blank with a disk + NIC, optionally booting an ISO |
| `vm-snapshot.yml` | Create / restore / delete a VM snapshot |
| `vm-migrate.yml` | Live-migrate a running VM between KVM hosts |

`create-vm.yml`, `vm-snapshot.yml` and `vm-migrate.yml` are pure Engine API
playbooks: like the `olvm_config` role they run on the controller
(`connection: local`) and never SSH into the Engine. They target the `engine`
inventory host only to reuse its `ansible_host` (the API endpoint) and the
vaulted `olvm_admin_password`. Run them from the `ansible/` project directory so
`ansible.cfg`, the inventory and the vault all resolve, and use the same
`ansible-core >= 2.16,<2.17` env with `ovirt-engine-sdk-python` installed that
the `olvm_config` role needs (see [`../ansible/README.md`](../ansible/README.md)).

Prerequisite for all VM helpers: the platform is configured (`site.yml` /
`olvm_config`) so the Data Center, cluster, an Up host, the `olvm-data` storage
domain and the `olvm-vm` vNIC profile exist.

## upload-disk.yml - upload a disk image / ISO to a storage domain

Uploads a disk image or ISO to an OLVM storage domain using the official oVirt
SDK example (`upload_disk.py`). It SSHes to the `engine` host, installs the SDK
and imageio client, writes a connection profile, downloads the image from a URL
onto the Engine, then runs `upload_disk.py` **on the Engine itself**.

This uses the same backend as the Admin Portal uploader (Engine REST API +
imageio daemon) but skips the browser, which is far more reliable for large
files. Running the upload remotely (from a workstation) has been reported to
fail with connection errors, so it always runs locally on the Engine.

### Run it

Run from the ansible project so `ansible.cfg`, the inventory, the vault and the
SSH key all resolve:

```sh
cd olvm-platform/ansible

ansible-playbook ../scripts/upload-disk.yml \
  -e upload_disk_image_url='https://yum.oracle.com/ISOS/OracleLinux/OL9/u7/x86_64/OracleLinux-R9-U7-x86_64-dvd.iso' \
  -e upload_disk_image_name='OracleLinux-R9-U7-x86_64-dvd.iso'
```

Or use the example vars file:

```sh
ansible-playbook ../scripts/upload-disk.yml -e @../scripts/upload-disk.vars.example.yml
```

A successful run prints the script's live progress and ends with
`Upload completed successfully`.

### Variables

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `upload_disk_image_url` | yes | - | https URL the Engine downloads the image from |
| `upload_disk_image_name` | yes | - | file name saved on the Engine and uploaded |
| `upload_disk_sd_name` | no | `olvm_storage_domain_name` (`olvm-data`) | target storage domain |
| `upload_disk_format` | no | `raw` | disk format (`raw` for ISOs) |
| `upload_disk_profile` | no | `OLVM-PROFILE` | connection profile name in `ovirt.conf` |
| `upload_disk_run_user` | no | `opc` | user that owns the config and runs the upload |
| `upload_disk_username` | no | `olvm_api_username` (`admin@ovirt@internalsso`) | API login |
| `upload_disk_cafile` | no | `/etc/pki/ovirt-engine/ca.pem` | Engine CA path |

The admin password is read from the vaulted `olvm_admin_password`
(auto-loaded from `inventory/group_vars/engine`).

### Notes

- **Username format:** Keycloak builds require the full profile suffix
  (`admin@ovirt@internalsso`), not the `admin@ovirt` you type in the portal.
  If Keycloak was declined during `engine-setup` (legacy AAA), set
  `upload_disk_username: admin@internal`.
- **Content type:** `upload_disk.py` auto-detects `iso` vs `data` from the file.
  Confirm the printed `Disk content type: iso` line for ISO uploads.
- **CA path:** if `/etc/pki/ovirt-engine/ca.pem` is missing, locate it with
  `sudo find /etc/pki/ovirt-engine -iname "*ca*.pem"` and set `upload_disk_cafile`.

## create-vm.yml - create a virtual machine

Creates a VM from the `Blank` template with a fresh bootable system disk on the
`olvm-data` domain and a NIC on the `olvm-vm` vNIC profile, optionally attaching
an uploaded ISO and booting it (cdrom first) to install an OS.

### Run it

```sh
cd olvm-platform/ansible

# minimal - a stopped VM with a blank 20 GiB disk
ansible-playbook ../scripts/create-vm.yml -e vm_name=lab-vm-01

# create and power on, booting an ISO uploaded earlier with upload-disk.yml
ansible-playbook ../scripts/create-vm.yml \
  -e vm_name=lab-vm-01 \
  -e vm_iso_name='OracleLinux-R9-U7-x86_64-dvd.iso' \
  -e vm_state=running

# or use the example vars file
ansible-playbook ../scripts/create-vm.yml -e @../scripts/create-vm.vars.example.yml
```

Open a console from Compute > Virtual Machines to complete the OS install.

### Variables

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `vm_name` | yes | - | VM name (unique in the cluster) |
| `vm_cluster` | no | `olvm-lab-cluster` | target cluster |
| `vm_memory` / `vm_memory_guaranteed` | no | `2GiB` | memory |
| `vm_cpu_cores` / `vm_cpu_sockets` | no | `1` / `1` | vCPU layout |
| `vm_operating_system` | no | `rhel_9x64` | guest OS hint |
| `vm_disk_size` | no | `20GiB` | system disk size |
| `vm_disk_format` | no | `cow` | `cow` (thin) or `raw` (preallocated) |
| `vm_disk_interface` | no | `virtio_scsi` | disk interface |
| `vm_storage_domain` | no | `olvm-data` | disk storage domain |
| `vm_nic_name` / `vm_nic_interface` | no | `nic1` / `virtio` | NIC name and model |
| `vm_vnic_profile` | no | `olvm-vm` | vNIC profile to attach the NIC to |
| `vm_iso_name` | no | `""` | uploaded ISO to boot (empty = blank disk) |
| `vm_state` | no | `present` | `present` (stopped) or `running` |

## vm-snapshot.yml - create / restore / delete a snapshot

Manages VM snapshots via `ovirt_snapshot`. For restore/delete the snapshot is
resolved from its description unless you pass an explicit `snapshot_id`.

### Run it

```sh
cd olvm-platform/ansible

# create (add snapshot_use_memory=true to capture a running VM's memory)
ansible-playbook ../scripts/vm-snapshot.yml \
  -e vm_name=lab-vm-01 -e snapshot_description=before-upgrade

# restore (stop the VM first for a clean disk+memory restore)
ansible-playbook ../scripts/vm-snapshot.yml \
  -e vm_name=lab-vm-01 -e snapshot_description=before-upgrade -e snapshot_action=restore

# delete
ansible-playbook ../scripts/vm-snapshot.yml \
  -e vm_name=lab-vm-01 -e snapshot_description=before-upgrade -e snapshot_action=delete
```

### Variables

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `vm_name` | yes | - | VM to snapshot |
| `snapshot_description` | yes | - | snapshot name; also used to find it for restore/delete |
| `snapshot_action` | no | `create` | `create` / `restore` / `delete` |
| `snapshot_use_memory` | no | `false` | include/restore live memory (guest is briefly paused) |
| `snapshot_id` | no | `""` | target a specific snapshot instead of matching the description |

> Restoring a VM discards any changes written after the snapshot was taken.

## vm-migrate.yml - live-migrate a VM between hosts

Live-migrates a running VM with `ovirt_vm` (`migrate: true`). It first asserts
the VM is Up and that at least two hosts are Up, then migrates to a chosen host
or lets the Engine pick one. Migration traffic uses the cluster's
migration-role network (`olvm-migration` when attached to the hosts; otherwise
oVirt falls back to `ovirtmgmt`).

### Run it

```sh
cd olvm-platform/ansible

# let the Engine choose the destination
ansible-playbook ../scripts/vm-migrate.yml -e vm_name=lab-vm-01

# target a specific host
ansible-playbook ../scripts/vm-migrate.yml -e vm_name=lab-vm-01 -e migrate_to_host=olvm-kvm-02
```

### Variables

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `vm_name` | yes | - | running VM to migrate |
| `migrate_to_host` | no | `""` | destination host name (empty = Engine chooses) |
| `migrate_force` | no | `false` | force even if the VM is pinned / non-migratable |
