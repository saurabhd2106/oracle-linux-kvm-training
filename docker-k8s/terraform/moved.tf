# Preserve the originally single VM (and its data volume/attachment) by mapping
# the old un-indexed resource addresses to the "vm1" key of the new for_each
# resources. This keeps the existing running instance in place instead of
# destroying and recreating it.
moved {
  from = oci_core_instance.linux
  to   = oci_core_instance.linux["vm1"]
}

moved {
  from = oci_core_volume.data
  to   = oci_core_volume.data["vm1"]
}

moved {
  from = oci_core_volume_attachment.data
  to   = oci_core_volume_attachment.data["vm1"]
}
