# Only VMs that explicitly request a data volume (data_volume_size_in_gbs set)
# get one. In the default topology that is just the NFS server, which exports the
# volume as an OLVM storage domain.
locals {
  data_volume_vms = {
    for k, v in var.vms : k => coalesce(v.data_volume_size_in_gbs, var.data_volume_size_in_gbs)
    if v.data_volume_size_in_gbs != null
  }
}

resource "oci_core_volume" "data" {
  for_each = local.data_volume_vms

  availability_domain = local.selected_availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${local.name_base}-${each.key}-data-volume"
  size_in_gbs         = each.value
  defined_tags        = var.defined_tags
  freeform_tags       = var.freeform_tags
}

# Use a paravirtualized attachment so the volume appears automatically as a
# standard block device (for example /dev/sdb) without requiring manual
# iscsiadm commands. The nfs_server Ansible role partitions, formats, and mounts
# it for the NFS export.
resource "oci_core_volume_attachment" "data" {
  for_each = local.data_volume_vms

  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.linux[each.key].id
  volume_id       = oci_core_volume.data[each.key].id
}
