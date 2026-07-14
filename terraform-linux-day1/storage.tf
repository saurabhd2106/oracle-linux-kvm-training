resource "oci_core_volume" "data" {
  availability_domain = local.selected_availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${var.project_name}-data-volume"
  size_in_gbs         = var.data_volume_size_in_gbs
  defined_tags        = var.defined_tags
  freeform_tags       = var.freeform_tags
}

# Use a paravirtualized attachment so the volume appears automatically as a
# standard block device (for example /dev/sdb) without requiring manual
# iscsiadm commands, keeping the lab focused on partitioning and filesystems
# rather than iSCSI mechanics.
resource "oci_core_volume_attachment" "data" {
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.linux.id
  volume_id       = oci_core_volume.data.id
  display_name    = "${var.project_name}-data-attachment"
}
