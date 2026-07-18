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
  description = "Personal prefix that makes every resource name unique so multiple people can run this code in the same tenancy, for example sau (yields sau-linux-ol8-vm)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,5}$", var.name_prefix))
    error_message = "name_prefix must be 2-6 characters, start with a lowercase letter, and contain only lowercase letters and numbers."
  }
}

variable "project_name" {
  description = "Short name used to label OCI resources."
  type        = string
  default     = "linux-ol8"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,30}$", var.project_name))
    error_message = "project_name must start with a letter and contain only letters, numbers, and hyphens."
  }
}

variable "instance_display_name" {
  description = "Optional override for the VM display name. When null, it is derived as <name_prefix>-<project_name>-vm."
  type        = string
  default     = null
}

variable "hostname_label" {
  description = "Optional override for the VM DNS hostname label. When null, it is derived from name_prefix and project_name."
  type        = string
  default     = null

  validation {
    condition     = var.hostname_label == null || can(regex("^[a-z][a-z0-9-]{1,14}$", var.hostname_label))
    error_message = "hostname_label must be 2-15 characters, start with a lowercase letter, and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "instance_shape" {
  description = "OCI compute shape for the VM. Default is VM.Standard.E5.Flex (x86, 4 OCPU / 16 GB), which meets the OLVM Engine's recommended sizing."
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
    condition     = var.instance_memory_in_gbs >= 16
    error_message = "instance_memory_in_gbs must be at least 16 GB for the OLVM Engine."
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

variable "oracle_linux_version" {
  description = "Oracle Linux operating system version used to find the latest matching image. The OLVM 4.5 Engine requires Oracle Linux 8.8+."
  type        = string
  default     = "8"
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
  description = "CIDR range allowed to connect to the VM over the allowed ingress ports."
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
    project    = "linux-ol8"
  }
}

variable "defined_tags" {
  description = "Defined tags applied to all supported OCI resources."
  type        = map(string)
  default     = {}
}
