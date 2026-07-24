# Secondary VNIC(s) for the KVM bridged-guest labs (Lab 4.1 Option 1 and Option 2).
#
# On OCI a bridged KVM guest cannot use an arbitrary MAC: the substrate only
# DHCPs the primary VNIC and drops traffic from MACs it does not know. Attaching
# a dedicated secondary VNIC gives the guest an Oracle-assigned MAC + private IP
# that the substrate recognizes. skip_source_dest_check is disabled so the host
# may also forward the guest's traffic if needed.
#
# Opt in per VM via var.secondary_vnic_vms (for example ["vm1"]). The
# kvm-scripting test scripts read the VNIC's MAC/IP from instance metadata
# (IMDS) at runtime, so no OCI credentials are needed on the host.

resource "oci_core_vnic_attachment" "kvm_guest" {
  for_each = toset([for k in var.secondary_vnic_vms : k if contains(keys(var.vms), k)])

  instance_id  = oci_core_instance.linux[each.value].id
  display_name = "${local.name_base}-${each.value}-guest-vnic-attachment"

  create_vnic_details {
    subnet_id              = oci_core_subnet.public.id
    display_name           = "${local.name_base}-${each.value}-guest-vnic"
    assign_public_ip       = false
    skip_source_dest_check = true

    defined_tags  = var.defined_tags
    freeform_tags = var.freeform_tags
  }
}

# Resolve the attached VNIC so its MAC address and private IP can be output for
# reference (the scripts still read these live from IMDS on the host).
data "oci_core_vnic" "kvm_guest" {
  for_each = oci_core_vnic_attachment.kvm_guest

  vnic_id = each.value.vnic_id
}
