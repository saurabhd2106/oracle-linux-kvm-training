# OCI Oracle Linux VM

This Terraform code provisions an Oracle Linux virtual machine on Oracle Cloud Infrastructure (OCI) with:

- Shape: `VM.Standard.E5.Flex`
- OCPUs: `4`
- Memory: `16 GB`
- Public subnet with internet gateway
- Public IP assigned to the VM
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
| VM display name | `sau-linux-day1-vm` |
| VM hostname label | `saulinuxday1` |
| VCN / subnet / gateway / etc. | `sau-linux-day1-vcn`, `sau-linux-day1-public-subnet`, ... |
| Data block volume | `sau-linux-day1-data-volume` |
| SSH private key path | `./generated/sau-linux-day1` |

You can still override `instance_display_name`, `hostname_label`, or `ssh_private_key_path` explicitly, but leaving them unset keeps names unique per person automatically.

The default compute settings already match the requested VM:

```hcl
instance_shape         = "VM.Standard.E5.Flex"
instance_ocpus         = 4
instance_memory_in_gbs = 16
```

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

After `terraform apply`, use the generated output:

```sh
terraform output ssh_command
```

Or connect manually:

```sh
ssh -i ./generated/sau-linux-day1 opc@<public-ip>
```

## Clean Up

Destroy the resources when they are no longer needed:

```sh
terraform destroy
```

The local generated SSH private key is managed by Terraform and will be removed when the `local_sensitive_file` resource is destroyed.
