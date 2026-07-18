data "oci_identity_availability_domains" "available" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "oracle_linux" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = var.oracle_linux_version
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  availability_domain_input    = var.availability_domain == null ? "" : trimspace(var.availability_domain)
  selected_availability_domain = local.availability_domain_input != "" ? local.availability_domain_input : data.oci_identity_availability_domains.available.availability_domains[0].name

  # name_base makes every resource name unique per person via name_prefix,
  # so multiple people can run this same code in the same tenancy.
  name_base             = "${var.name_prefix}-${var.project_name}"
  instance_display_name = coalesce(var.instance_display_name, "${local.name_base}-vm")
  hostname_label        = coalesce(var.hostname_label, substr(replace("${var.name_prefix}${var.project_name}", "-", ""), 0, 15))
  ssh_private_key_path  = coalesce(var.ssh_private_key_path, "./generated/${local.name_base}")
}

resource "oci_core_instance" "linux" {
  availability_domain = local.selected_availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = local.instance_display_name
  shape               = var.instance_shape

  # Flex shapes (for example VM.Standard.E5.Flex) require shape_config, while
  # fixed Always Free shapes (for example VM.Standard.E2.1.Micro) reject it.
  dynamic "shape_config" {
    for_each = endswith(var.instance_shape, "Flex") ? [1] : []
    content {
      ocpus         = var.instance_ocpus
      memory_in_gbs = var.instance_memory_in_gbs
    }
  }

  create_vnic_details {
    assign_public_ip = true
    display_name     = "${local.name_base}-primary-vnic"
    hostname_label   = local.hostname_label
    subnet_id        = oci_core_subnet.public.id
  }

  source_details {
    source_id               = data.oci_core_images.oracle_linux.images[0].id
    source_type             = "image"
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
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
