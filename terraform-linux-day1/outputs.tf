output "instance_id" {
  description = "OCID of the Oracle Linux VM."
  value       = oci_core_instance.linux.id
}

output "instance_public_ip" {
  description = "Public IP address assigned to the Oracle Linux VM."
  value       = oci_core_instance.linux.public_ip
}

output "instance_private_ip" {
  description = "Private IP address assigned to the Oracle Linux VM."
  value       = oci_core_instance.linux.private_ip
}

output "public_subnet_id" {
  description = "OCID of the public subnet."
  value       = oci_core_subnet.public.id
}

output "ssh_private_key_path" {
  description = "Local path to the generated SSH private key."
  value       = local.ssh_private_key_path
}

output "ssh_command" {
  description = "SSH command for connecting to the VM as the default Oracle Linux user."
  value       = "ssh -i ${local.ssh_private_key_path} opc@${oci_core_instance.linux.public_ip}"
}

# The in-guest device name (for example /dev/sdb) is assigned by the guest OS at
# attach time, not by OCI, so it cannot be output directly from Terraform.
output "data_volume_ocid" {
  description = "OCID of the attached data block volume, for reference"
  value       = oci_core_volume.data.id
}
