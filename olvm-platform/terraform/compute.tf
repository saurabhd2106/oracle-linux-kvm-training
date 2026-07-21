data "oci_identity_availability_domains" "available" {
  compartment_id = var.tenancy_ocid
}

locals {
  availability_domain_input    = var.availability_domain == null ? "" : trimspace(var.availability_domain)
  selected_availability_domain = local.availability_domain_input != "" ? local.availability_domain_input : data.oci_identity_availability_domains.available.availability_domains[0].name

  # name_base makes every resource name unique per person via name_prefix,
  # so multiple people can run this same code in the same tenancy.
  name_base            = "${var.name_prefix}-${var.project_name}"
  ssh_private_key_path = coalesce(var.ssh_private_key_path, "./generated/${local.name_base}")

  # Resolve the shape and OS version per VM (per-VM override falling back to the
  # global default) so the image lookup below matches each VM's architecture and
  # OS. The Engine runs Oracle Linux 8 while the KVM hosts and NFS server run
  # Oracle Linux 9, so images must be looked up per (shape, os_version) pair.
  vm_shapes      = { for k, v in var.vms : k => coalesce(v.instance_shape, var.instance_shape) }
  vm_os_versions = { for k, v in var.vms : k => coalesce(v.oracle_linux_version, var.oracle_linux_version) }
  vm_image_keys  = { for k, v in var.vms : k => "${local.vm_shapes[k]}::${local.vm_os_versions[k]}" }
  distinct_images = { for key in distinct(values(local.vm_image_keys)) : key => {
    shape      = split("::", key)[0]
    os_version = split("::", key)[1]
  } }

  # Role helpers, used by outputs.tf to build the Ansible inventory. A VM with no
  # explicit role is treated as a generic host and excluded from the groups.
  vm_roles         = { for k, v in var.vms : k => coalesce(v.role, "") }
  engine_vm_keys   = [for k, r in local.vm_roles : k if r == "engine"]
  kvm_host_vm_keys = [for k, r in local.vm_roles : k if r == "kvm_host"]
  nfs_vm_keys      = [for k, r in local.vm_roles : k if r == "nfs"]
}

# Latest Oracle Linux image per distinct (shape, os_version) pair in use. Keyed
# by "<shape>::<os_version>" so mixed architectures and mixed OS versions (OL8
# Engine vs OL9 KVM/NFS) each resolve to a compatible image.
data "oci_core_images" "oracle_linux" {
  for_each = local.distinct_images

  compartment_id           = var.compartment_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = each.value.os_version
  shape                    = each.value.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "linux" {
  for_each = var.vms

  availability_domain = local.selected_availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = coalesce(each.value.display_name, "${local.name_base}-${each.key}")
  shape               = local.vm_shapes[each.key]

  # Flex shapes (for example VM.Standard.A1.Flex) require shape_config, while
  # fixed Always Free shapes (for example VM.Standard.E2.1.Micro) reject it.
  dynamic "shape_config" {
    for_each = endswith(local.vm_shapes[each.key], "Flex") ? [1] : []
    content {
      ocpus         = coalesce(each.value.instance_ocpus, var.instance_ocpus)
      memory_in_gbs = coalesce(each.value.instance_memory_in_gbs, var.instance_memory_in_gbs)
    }
  }

  create_vnic_details {
    assign_public_ip = true
    display_name     = "${local.name_base}-${each.key}-primary-vnic"
    # Keep the per-VM key so each hostname is unique in the subnet. Derive from
    # name_prefix + key only (project_name is dropped here) because the 15-char
    # DNS label limit would otherwise truncate the distinguishing key off a long
    # project_name and collide (e.g. all VMs -> "sauolvmplatform").
    hostname_label = coalesce(each.value.hostname_label, substr(replace("${var.name_prefix}-${each.key}", "-", ""), 0, 15))
    subnet_id      = oci_core_subnet.public.id
  }

  source_details {
    source_id               = data.oci_core_images.oracle_linux[local.vm_image_keys[each.key]].images[0].id
    source_type             = "image"
    boot_volume_size_in_gbs = coalesce(each.value.boot_volume_size_in_gbs, var.boot_volume_size_in_gbs)
  }

  metadata = {
    ssh_authorized_keys = tls_private_key.vm_ssh.public_key_openssh
  }

  preserve_boot_volume = false
  defined_tags         = var.defined_tags
  freeform_tags        = merge(var.freeform_tags, { role = local.vm_roles[each.key] })

  # The image data source is filtered by shape/OS, so changing either returns a
  # newer "latest" image. OCI rejects reimaging the boot volume in the same
  # request that revises the instance shape, so ignore image drift on an
  # already-provisioned instance and only apply the shape/OCPU/memory changes.
  lifecycle {
    ignore_changes = [source_details]
  }
}
