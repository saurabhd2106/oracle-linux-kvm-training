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
  description = "Personal prefix that makes every resource name unique so multiple people can run this code in the same tenancy, for example sau (yields sau-linux-day1-vm)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,5}$", var.name_prefix))
    error_message = "name_prefix must be 2-6 characters, start with a lowercase letter, and contain only lowercase letters and numbers."
  }
}

variable "project_name" {
  description = "Short name used to label OCI resources."
  type        = string
  default     = "linux-day1"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,30}$", var.project_name))
    error_message = "project_name must start with a letter and contain only letters, numbers, and hyphens."
  }
}

variable "vms" {
  description = "Map of VMs to create, keyed by short name. An empty object {} uses the global defaults; set any field to override it for that VM. Networking and the SSH keypair are shared across all VMs."
  type = map(object({
    display_name            = optional(string)
    hostname_label          = optional(string)
    instance_shape          = optional(string)
    instance_ocpus          = optional(number)
    instance_memory_in_gbs  = optional(number)
    boot_volume_size_in_gbs = optional(number)
    data_volume_size_in_gbs = optional(number)
  }))
  default = {
    vm1 = {}
    vm2 = {}
    vm3 = {}
  }

  validation {
    condition = alltrue([
      for k, v in var.vms : v.hostname_label == null || can(regex("^[a-z][a-z0-9-]{1,14}$", v.hostname_label))
    ])
    error_message = "each vms hostname_label must be 2-15 characters, start with a lowercase letter, and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "instance_shape" {
  description = "OCI compute shape for the VM. Lab default is VM.Standard.E5.Flex (x86, 4 OCPU / 16 GB). Always Free options: VM.Standard.E2.1.Micro (fixed, AMD) or VM.Standard.A1.Flex (Ampere ARM, up to 4 OCPU / 24 GB free)."
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
  description = "Amount of memory in GB for flex shapes only (ignored for fixed shapes like VM.Standard.E2.1.Micro)."
  type        = number
  default     = 16

  validation {
    condition     = var.instance_memory_in_gbs > 0
    error_message = "instance_memory_in_gbs must be greater than 0."
  }
}

variable "boot_volume_size_in_gbs" {
  description = "Boot volume size in GB."
  type        = number
  default     = 50

  validation {
    condition     = var.boot_volume_size_in_gbs >= 50
    error_message = "boot_volume_size_in_gbs must be at least 50 GB."
  }
}

variable "data_volume_size_in_gbs" {
  description = "Size in GB of the secondary block volume attached for the storage lab"
  type        = number
  default     = 50
}

variable "oracle_linux_version" {
  description = "Oracle Linux operating system version used to find the latest matching image."
  type        = string
  default     = "9"
}

variable "vcn_cidr_block" {
  description = "CIDR block for the VCN."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr_block" {
  description = "CIDR block for the public subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "ssh_allowed_cidr" {
  description = "CIDR range allowed to connect to the VM over SSH."
  type        = string
  default     = "0.0.0.0/0"
}

variable "allowed_ingress_ports" {
  description = "TCP ports allowed inbound from ssh_allowed_cidr on the public security list."
  type        = list(number)
  default     = [22]

  validation {
    condition = alltrue([
      for port in var.allowed_ingress_ports : port >= 1 && port <= 65535
    ])
    error_message = "allowed_ingress_ports values must be between 1 and 65535."
  }
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
    project    = "linux-day1"
  }
}

variable "defined_tags" {
  description = "Defined tags applied to all supported OCI resources."
  type        = map(string)
  default     = {}
}
