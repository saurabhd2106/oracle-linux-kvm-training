# OCI Oracle Linux 8 VM for OLVM

This Terraform code provisions an **Oracle Linux 8** virtual machine on Oracle
Cloud Infrastructure (OCI), sized and opened for the **Oracle Linux
Virtualization Manager (OLVM) 4.5 Engine**. It is the host consumed by the
[`../install-olvm`](../install-olvm/) Ansible project.

- Shape: `VM.Standard.E5.Flex`
- OCPUs: `4`
- Memory: `16 GB` (OLVM Engine recommended)
- Boot volume: `100 GB` (Engine + PostgreSQL + DWH + Grafana + Keycloak + logs)
- OS: Oracle Linux `8` (OLVM 4.5 requires OL 8.8+)
- Public subnet with internet gateway
- Public IP assigned to the VM
- Inbound TCP `22` (SSH), `80` and `443` (Engine web portals)
- Terraform-generated SSH key pair for `opc` login

## Prerequisites

- Terraform `1.5.0` or newer
- OCI tenancy, user, and compartment OCIDs
- OCI API signing key configured for the Terraform user
- IAM policy that allows the Terraform user to manage networking and compute resources in the target compartment

Example OCI policy:

```text
Allow group <group-name> to manage all-resources in compartment <compartment-name>
```

For tighter production access, replace `all-resources` with the exact OCI resource families your organization allows.

## Files

- `versions.tf`: Terraform and provider version constraints
- `provider.tf`: OCI provider configuration
- `variables.tf`: Input variables and defaults
- `network.tf`: VCN, internet gateway, route table, security list, and public subnet
- `ssh.tf`: Generated SSH key pair and local private key file
- `compute.tf`: Oracle Linux compute instance
- `outputs.tf`: Instance details and SSH connection command
- `terraform.tfvars.example`: Safe example values

## Configure

Copy the example variable file and update it with your OCI values:

```sh
cp terraform.tfvars.example terraform.tfvars
```

Required values:

```hcl
tenancy_ocid     = "ocid1.tenancy.oc1..exampleuniqueid"
user_ocid        = "ocid1.user.oc1..exampleuniqueid"
fingerprint      = "00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00"
private_key_path = "~/.oci/oci_api_key.pem"
region           = "ap-sydney-1"
compartment_ocid = "ocid1.compartment.oc1..exampleuniqueid"
name_prefix      = "sau"
```

### Unique names for shared tenancies

Set a unique `name_prefix` (2-6 lowercase alphanumeric characters, for example `sau`) so multiple people can run this same code in the same OCI tenancy without name clashes. Every resource name is derived from it:

| Resource | Example name (`name_prefix = "sau"`) |
|---|---|
| VM display name | `sau-linux-ol8-vm` |
| VM hostname label | `saulinuxol8` |
| VCN / subnet / gateway / etc. | `sau-linux-ol8-vcn`, `sau-linux-ol8-public-subnet`, ... |
| SSH private key path | `./generated/sau-linux-ol8` |

You can still override `instance_display_name`, `hostname_label`, or `ssh_private_key_path` explicitly, but leaving them unset keeps names unique per person automatically.

The default compute settings already match the OLVM Engine's recommended sizing:

```hcl
instance_shape         = "VM.Standard.E5.Flex"
instance_ocpus         = 4
instance_memory_in_gbs = 16
oracle_linux_version   = "8"
```

For better security, set `ssh_allowed_cidr` to your public IP address or trusted network instead of leaving it open:

```hcl
ssh_allowed_cidr = "203.0.113.10/32"
```

Inbound TCP ports are controlled by `allowed_ingress_ports`. The default opens SSH plus the Engine web portals; add any port you need and re-apply. Every port is opened from `ssh_allowed_cidr`:

```hcl
allowed_ingress_ports = [22, 80, 443]
```

To open a contiguous range of ports as a single rule, use `allowed_ingress_port_ranges`. The default opens the OLVM console (VNC/SPICE) proxy range so VM consoles are reachable. Ranges are opened from the same `ssh_allowed_cidr`, so tighten `ssh_allowed_cidr` to a trusted network before exposing the console range:

```hcl
allowed_ingress_port_ranges = [{ min = 5900, max = 6923 }]
```

## Deploy

Initialize Terraform:

```sh
terraform init
```

Review the execution plan:

```sh
terraform plan
```

Create the resources:

```sh
terraform apply
```

Terraform writes the generated VM private key to the path from `ssh_private_key_path`, which defaults to `./generated/<name_prefix>-<project_name>`, for example:

```text
./generated/sau-linux-ol8
```

The file is created with `0600` permissions and is ignored by Git.

## Connect

After `terraform apply`, use the generated output:

```sh
terraform output ssh_command
```

Or connect manually:

```sh
ssh -i ./generated/sau-linux-ol8 opc@<public-ip>
```

## Deploy OLVM on this host

Once the VM is up, hand it off to the [`../install-olvm`](../install-olvm/) Ansible project:

```sh
terraform output -raw instance_public_ip   # set as ansible_host in install-olvm inventory
terraform output -raw ssh_private_key_path  # matches install-olvm ansible.cfg private_key_file
```

See [`../install-olvm/README.md`](../install-olvm/README.md) for the full Engine install steps.

## Clean Up

Destroy the resources when they are no longer needed:

```sh
terraform destroy
```

The local generated SSH private key is managed by Terraform and will be removed when the `local_sensitive_file` resource is destroyed.
