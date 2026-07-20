output "instance_ids" {
  description = "Map of VM name to the OCID of the Oracle Linux VM."
  value       = { for k, i in oci_core_instance.linux : k => i.id }
}

output "instance_public_ips" {
  description = "Map of VM name to the public IP address assigned to the VM."
  value       = { for k, i in oci_core_instance.linux : k => i.public_ip }
}

output "instance_private_ips" {
  description = "Map of VM name to the private IP address assigned to the VM."
  value       = { for k, i in oci_core_instance.linux : k => i.private_ip }
}

output "public_subnet_id" {
  description = "OCID of the public subnet (shared by all VMs)."
  value       = oci_core_subnet.public.id
}

output "ssh_private_key_path" {
  description = "Local path to the generated SSH private key (shared by all VMs)."
  value       = local.ssh_private_key_path
}

output "ssh_commands" {
  description = "Map of VM name to the SSH command for connecting as the default Oracle Linux user."
  value       = { for k, i in oci_core_instance.linux : k => "ssh -i ${local.ssh_private_key_path} opc@${i.public_ip}" }
}

# The in-guest device name (for example /dev/sdb) is assigned by the guest OS at
# attach time, not by OCI, so it cannot be output directly from Terraform.
output "data_volume_ocids" {
  description = "Map of VM name to the OCID of its attached data block volume, for reference."
  value       = { for k, v in oci_core_volume.data : k => v.id }
}
