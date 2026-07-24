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

  # Resolve the shape per VM (per-VM override falling back to the global default)
  # so the image lookup below can match each VM's shape/architecture.
  vm_shapes       = { for k, v in var.vms : k => coalesce(v.instance_shape, var.instance_shape) }
  distinct_shapes = toset(values(local.vm_shapes))

  # OCI hostname_label / DNS labels allow only [a-z0-9-], max 15 chars, and must
  # not end with "-". Strip "-" and "_" from the derived name so keys like
  # control_plane / worker_node do not produce invalid labels (e.g. sdlinuxcontrol_).
  vm_hostname_labels = {
    for k, v in var.vms : k => coalesce(
      v.hostname_label,
      substr(replace(replace("${var.name_prefix}${var.project_name}${k}", "-", ""), "_", ""), 0, 15)
    )
  }
}

# Latest base Oracle Linux platform image per distinct shape in use. Keyed by
# shape so mixed architectures (for example x86 VM.Standard.E5.Flex and ARM
# VM.Standard.A1.Flex) each resolve to a compatible image.
#
# The display_name filter keeps the simple platform image
# (Oracle-Linux-<ver>.x-YYYY.MM.DD-0) and excludes heavier specialized images
# such as Cloud Developer, Minimal, GPU, and KVM builds — enough for Docker
# and Kubernetes demos without the extra preinstalled stacks.
data "oci_core_images" "oracle_linux" {
  for_each = local.distinct_shapes

  compartment_id           = var.compartment_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = var.oracle_linux_version
  shape                    = each.value
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  filter {
    name   = "display_name"
    values = ["^Oracle-Linux-${var.oracle_linux_version}\\.[0-9]+-[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}-0$"]
    regex  = true
  }
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
    hostname_label   = local.vm_hostname_labels[each.key]
    subnet_id        = oci_core_subnet.public.id
  }

  source_details {
    source_id               = data.oci_core_images.oracle_linux[local.vm_shapes[each.key]].images[0].id
    source_type             = "image"
    boot_volume_size_in_gbs = coalesce(each.value.boot_volume_size_in_gbs, var.boot_volume_size_in_gbs)
  }

  metadata = {
    ssh_authorized_keys = tls_private_key.vm_ssh.public_key_openssh
  }

  preserve_boot_volume = false
  defined_tags         = var.defined_tags
  freeform_tags        = var.freeform_tags

  # The image data source is filtered by shape, so changing the shape returns a
  # newer "latest" image. OCI rejects reimaging the boot volume in the same
  # request that revises the instance shape, so ignore image drift on an
  # already-provisioned instance and only apply the shape/OCPU/memory changes.
  lifecycle {
    ignore_changes = [source_details]
  }
}
