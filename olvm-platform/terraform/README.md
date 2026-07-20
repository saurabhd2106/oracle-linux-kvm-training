# Terraform: OLVM platform infrastructure

Single OCI Terraform stack that provisions the whole OLVM lab in one apply:

| VM key | Role | OS | Default size | Data volume |
|--------|------|----|--------------|-------------|
| `engine` | OLVM Engine (Manager) | Oracle Linux 8 | 4 OCPU / 16 GB / 100 GB boot | no |
| `kvm1` | KVM host | Oracle Linux 9 | 4 OCPU / 16 GB | no |
| `kvm2` | KVM host | Oracle Linux 9 | 4 OCPU / 16 GB | no |
| `nfs` | NFS storage server | Oracle Linux 9 | 2 OCPU / 8 GB | yes (200 GB) |

All VMs share one VCN, public subnet, internet gateway, security list, and one
Terraform-generated SSH keypair (written to `./generated/<name_prefix>-<project_name>`).

## What this creates

- `oci_core_vcn`, `oci_core_internet_gateway`, `oci_core_route_table`, `oci_core_subnet`
- `oci_core_security_list` with:
  - external ingress from `ssh_allowed_cidr`: TCP 22, 80, 443 and range 5900-6923
  - **intra-VCN allow-all** (`allow_all_intra_vcn = true`): every port between machines inside `vcn_cidr_block`
  - egress: all
- `oci_core_instance` per entry in `var.vms` (image resolved per shape + OS version)
- `oci_core_volume` + `oci_core_volume_attachment` for VMs that set `data_volume_size_in_gbs` (the NFS server)
- `tls_private_key` + local private key file

## Usage

```sh
cp terraform.tfvars.example terraform.tfvars   # fill in OCI credentials
terraform init
terraform plan
terraform apply
```

## Outputs for the Ansible step

```sh
terraform output ansible_inventory_hint   # engine / kvm_hosts / nfs_server IPs
terraform output -raw engine_public_ip
terraform output kvm_host_public_ips
terraform output -raw nfs_public_ip
terraform output -raw nfs_private_ip
terraform output -raw ssh_private_key_path
```

Feed these into `../ansible/inventory/hosts.yml` (see `../ansible/README` and the
top-level `../README.md` for the end-to-end flow).

## Cleanup

```sh
terraform destroy
```
