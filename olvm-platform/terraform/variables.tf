variable "tenancy_ocid" {
  description = "OCID of the OCI tenancy."
  type        = string
}

variable "user_ocid" {
  description = "OCID of the OCI user used by Terraform."
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint of the OCI API signing key."
  type        = string
}

variable "private_key_path" {
  description = "Local path to the OCI API private key."
  type        = string
}

variable "region" {
  description = "OCI region identifier, for example ap-sydney-1."
  type        = string
}

variable "compartment_ocid" {
  description = "OCID of the compartment where resources will be created."
  type        = string
}

variable "availability_domain" {
  description = "Optional availability domain name. If null, the first availability domain in the tenancy is used."
  type        = string
  default     = null
}

variable "name_prefix" {
  description = "Personal prefix that makes every resource name unique so multiple people can run this code in the same tenancy, for example sau (yields sau-olvm-platform-engine)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,5}$", var.name_prefix))
    error_message = "name_prefix must be 2-6 characters, start with a lowercase letter, and contain only lowercase letters and numbers."
  }
}

variable "project_name" {
  description = "Short name used to label OCI resources."
  type        = string
  default     = "olvm-platform"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,30}$", var.project_name))
    error_message = "project_name must start with a letter and contain only letters, numbers, and hyphens."
  }
}

variable "vms" {
  description = <<-EOT
    Map of VMs to create, keyed by short name. An empty object {} uses the global
    defaults; set any field to override it for that VM. Networking and the SSH
    keypair are shared across all VMs.

    role                 - logical role of the VM: engine | kvm_host | nfs. Drives
                           the grouped outputs used to build the Ansible inventory.
    oracle_linux_version - per-VM OS major version (the OLVM Engine needs "8"; the
                           KVM hosts and NFS server use "9"). Falls back to the
                           global oracle_linux_version when unset.
    data_volume_size_in_gbs - when set, a paravirtualized block volume of this size
                              is attached to the VM (used for the NFS export). When
                              null, no data volume is created for the VM.
  EOT
  type = map(object({
    role                    = optional(string)
    display_name            = optional(string)
    hostname_label          = optional(string)
    instance_shape          = optional(string)
    instance_ocpus          = optional(number)
    instance_memory_in_gbs  = optional(number)
    boot_volume_size_in_gbs = optional(number)
    data_volume_size_in_gbs = optional(number)
    oracle_linux_version    = optional(string)
  }))
  default = {
    engine = {
      role                 = "engine"
      oracle_linux_version = "8"
    }
    kvm1 = {
      role                 = "kvm_host"
      oracle_linux_version = "9"
    }
    kvm2 = {
      role                 = "kvm_host"
      oracle_linux_version = "9"
    }
    nfs = {
      role                    = "nfs"
      oracle_linux_version    = "9"
      data_volume_size_in_gbs = 200
    }
  }

  validation {
    condition = alltrue([
      for k, v in var.vms : v.hostname_label == null || can(regex("^[a-z][a-z0-9-]{1,14}$", v.hostname_label))
    ])
    error_message = "each vms hostname_label must be 2-15 characters, start with a lowercase letter, and contain only lowercase letters, numbers, and hyphens."
  }

  validation {
    condition = alltrue([
      for k, v in var.vms : v.role == null || contains(["engine", "kvm_host", "nfs"], v.role)
    ])
    error_message = "each vms role must be one of: engine, kvm_host, nfs."
  }
}

variable "instance_shape" {
  description = "OCI compute shape for the VMs. Default is VM.Standard.E5.Flex (x86, 4 OCPU / 16 GB), which meets the OLVM Engine's recommended sizing."
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "instance_ocpus" {
  description = "Number of OCPUs for flex shapes only (ignored for fixed shapes like VM.Standard.E2.1.Micro)."
  type        = number
  default     = 4

  validation {
    condition     = var.instance_ocpus > 0
    error_message = "instance_ocpus must be greater than 0."
  }
}

variable "instance_memory_in_gbs" {
  description = "Amount of memory in GB for flex shapes only (ignored for fixed shapes). Defaults to the OLVM Engine's recommended 16 GB."
  type        = number
  default     = 16

  validation {
    condition     = var.instance_memory_in_gbs > 0
    error_message = "instance_memory_in_gbs must be greater than 0."
  }
}

variable "boot_volume_size_in_gbs" {
  description = "Boot volume size in GB. Defaults to 100 GB to hold the Engine, PostgreSQL, DWH, Grafana, Keycloak, and their logs."
  type        = number
  default     = 100

  validation {
    condition     = var.boot_volume_size_in_gbs >= 50
    error_message = "boot_volume_size_in_gbs must be at least 50 GB."
  }
}

variable "data_volume_size_in_gbs" {
  description = "Default size in GB of the secondary block volume, used when a VM sets data_volume_size_in_gbs without an explicit value. Only VMs that request a data volume get one."
  type        = number
  default     = 200
}

variable "oracle_linux_version" {
  description = "Global default Oracle Linux OS version used when a VM does not set its own oracle_linux_version. The OLVM 4.5 Engine requires Oracle Linux 8.8+; the KVM hosts require Oracle Linux 9.6+."
  type        = string
  default     = "9"
}

variable "vcn_cidr_block" {
  description = "CIDR block for the VCN. Also used as the source for the intra-VCN allow-all rule so the machines can talk to each other over every OLVM/libvirt/migration/NFS port."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr_block" {
  description = "CIDR block for the public subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "ssh_allowed_cidr" {
  description = "CIDR range allowed to connect to the VMs over the external ingress ports (SSH and the OLVM web portals/console)."
  type        = string
  default     = "0.0.0.0/0"
}

variable "allowed_ingress_ports" {
  description = "TCP ports allowed inbound from ssh_allowed_cidr on the public security list. Defaults to SSH (22) plus the OLVM Engine web portals (80, 443)."
  type        = list(number)
  default     = [22, 80, 443]

  validation {
    condition = alltrue([
      for port in var.allowed_ingress_ports : port >= 1 && port <= 65535
    ])
    error_message = "allowed_ingress_ports values must be between 1 and 65535."
  }
}

variable "allowed_ingress_port_ranges" {
  description = "Contiguous TCP port ranges allowed inbound from ssh_allowed_cidr on the public security list. Each range opens as a single rule. Defaults to the OLVM console (VNC/SPICE) proxy range 5900-6923."
  type = list(object({
    min = number
    max = number
  }))
  default = [{ min = 5900, max = 6923 }]

  validation {
    condition = alltrue([
      for range in var.allowed_ingress_port_ranges :
      range.min >= 1 && range.min <= 65535 && range.max >= 1 && range.max <= 65535 && range.min <= range.max
    ])
    error_message = "allowed_ingress_port_ranges values must be between 1 and 65535, and min must be less than or equal to max."
  }
}

variable "allow_all_intra_vcn" {
  description = "When true, add a security-list rule allowing all protocols/ports between machines inside vcn_cidr_block. This covers every internal OLVM (vdsm 54321/54322), libvirt (16509/16514), live-migration (49152-49216), console (5900-6923), NFS (2049/111/20048) and SSH port needed for the machines to communicate."
  type        = bool
  default     = true
}

variable "ssh_private_key_path" {
  description = "Optional override for the local path where Terraform writes the generated VM SSH private key. When null, it is derived as ./generated/<name_prefix>-<project_name>."
  type        = string
  default     = null
}

variable "freeform_tags" {
  description = "Freeform tags applied to all supported OCI resources."
  type        = map(string)
  default = {
    managed-by = "terraform"
    project    = "olvm-platform"
  }
}

variable "defined_tags" {
  description = "Defined tags applied to all supported OCI resources."
  type        = map(string)
  default     = {}
}
