# OCI Oracle Linux VMs

This Terraform code provisions a single Oracle Linux virtual machine on Oracle Cloud Infrastructure (OCI) by default. Additional VMs and their per-VM settings are configurable via the `vms` map. Each VM gets:

- Shape: `VM.Standard.E5.Flex` (default, per-VM overridable)
- OCPUs: `4` (default, per-VM overridable)
- Memory: `16 GB` (default, per-VM overridable)
- Its own attached data block volume
- A public IP on a shared public subnet with internet gateway

Networking (VCN, subnet, internet gateway, route table, security list) and a single Terraform-generated SSH key pair for `opc` login are shared across all VMs.

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
- `network.tf`: VCN, internet gateway, route table, security list, and public subnet (shared)
- `ssh.tf`: Generated SSH key pair and local private key file (shared)
- `compute.tf`: Oracle Linux compute instances (one per entry in `vms`)
- `storage.tf`: Per-VM data block volumes and attachments
- `moved.tf`: State-migration blocks that preserve the original single VM as `vm1`
- `outputs.tf`: Per-VM instance details and SSH connection commands
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

Set a unique `name_prefix` (2-6 lowercase alphanumeric characters, for example `sau`) so multiple people can run this same code in the same OCI tenancy without name clashes. Every resource name is derived from it and the VM key:

| Resource | Example name (`name_prefix = "sau"`, VM key `vm1`) |
|---|---|
| VM display name | `sau-linux-day1-vm1` |
| VM hostname label | `saulinuxday1vm1` (underscores stripped; max 15 chars) |
| VCN / subnet / gateway / etc. | `sau-linux-day1-vcn`, `sau-linux-day1-public-subnet`, ... |
| Data block volume | `sau-linux-day1-vm1-data-volume` |
| SSH private key path (shared) | `./generated/sau-linux-day1` |

You can override a VM's `display_name` or `hostname_label` per entry in the `vms` map, or override `ssh_private_key_path` globally, but leaving them unset keeps names unique per person automatically.

### Configuring the VMs

The `vms` variable is a map keyed by short VM name. The number of VMs equals the number of entries; by default it contains a single `vm1` entry. Add or remove keys to scale up or down. An empty object `{}` uses the global defaults; set any field to override it for that VM:

```hcl
vms = {
  vm1 = {}
}
```

To create more VMs, add entries and optionally override per-VM fields:

```hcl
vms = {
  vm1 = {}
  vm2 = {}
  vm3 = {
    instance_ocpus          = 2
    instance_memory_in_gbs  = 8
    data_volume_size_in_gbs = 100
  }
}
```

Per-VM overridable fields: `display_name`, `hostname_label`, `instance_shape`, `instance_ocpus`, `instance_memory_in_gbs`, `boot_volume_size_in_gbs`, `data_volume_size_in_gbs`. Any field left unset falls back to the global defaults:

```hcl
instance_shape         = "VM.Standard.E5.Flex"
instance_ocpus         = 4
instance_memory_in_gbs = 16
```

Mixed architectures are supported: the latest **base** Oracle Linux platform image is resolved per distinct shape (specialized Cloud Developer / GPU / Minimal / KVM images are filtered out), so you can mix x86 (`VM.Standard.E5.Flex`) and ARM (`VM.Standard.A1.Flex`) VMs in the same `vms` map.

> Preserving the original VM: if you previously applied this code when it created a single VM, the `moved` blocks in `moved.tf` map that instance (and its data volume/attachment) to the `vm1` key. Keep a `vm1` entry in `vms` so `terraform plan` shows `vm1` updated in place (a display-name/hostname rename) rather than destroyed and recreated.

For better security, set `ssh_allowed_cidr` to your public IP address or trusted network instead of leaving it open:

```hcl
ssh_allowed_cidr = "203.0.113.10/32"
```

Inbound TCP ports are controlled by `allowed_ingress_ports`. Add any port you need to the list and re-apply; every port is opened from `ssh_allowed_cidr`:

```hcl
allowed_ingress_ports = [22, 80, 8080]
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
./generated/sau-linux-day1
```

The file is created with `0600` permissions and is ignored by Git.

## Connect

After `terraform apply`, the SSH commands are output per VM as a map:

```sh
terraform output ssh_commands
```

To connect to a specific VM by key:

```sh
$(terraform output -raw -json ssh_commands | jq -r '.vm1')
```

Or connect manually using the public IP from `terraform output instance_public_ips`:

```sh
ssh -i ./generated/sau-linux-day1 opc@<public-ip>
```

## Clean Up

Destroy the resources when they are no longer needed:

```sh
terraform destroy
```

The local generated SSH private key is managed by Terraform and will be removed when the `local_sensitive_file` resource is destroyed.
