resource "oci_core_volume" "data" {
  for_each = var.vms

  availability_domain = local.selected_availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${local.name_base}-${each.key}-data-volume"
  size_in_gbs         = coalesce(each.value.data_volume_size_in_gbs, var.data_volume_size_in_gbs)
  defined_tags        = var.defined_tags
  freeform_tags       = var.freeform_tags
}

# Use a paravirtualized attachment so the volume appears automatically as a
# standard block device (for example /dev/sdb) without requiring manual
# iscsiadm commands, keeping the lab focused on partitioning and filesystems
# rather than iSCSI mechanics.
# display_name is intentionally omitted: it is ForceNew on volume attachments,
# so setting it would force a disruptive detach/reattach of the already-attached
# data volume on the preserved vm1 instance. Leaving it unset keeps the existing
# attachment in place and lets OCI auto-generate names for new attachments.
resource "oci_core_volume_attachment" "data" {
  for_each = var.vms

  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.linux[each.key].id
  volume_id       = oci_core_volume.data[each.key].id
}
