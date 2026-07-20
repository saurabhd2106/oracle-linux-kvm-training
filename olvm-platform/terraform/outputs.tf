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

output "vcn_cidr_block" {
  description = "CIDR block of the VCN, allowed for all intra-VCN machine-to-machine traffic."
  value       = var.vcn_cidr_block
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

# --- Role-grouped outputs (used to build the Ansible inventory) --------------

output "engine_public_ip" {
  description = "Public IP of the OLVM Engine host (the machine OLVM is installed on). Use as ansible_host for the engine group."
  value       = length(local.engine_vm_keys) > 0 ? oci_core_instance.linux[local.engine_vm_keys[0]].public_ip : null
}

output "engine_private_ip" {
  description = "Private IP of the OLVM Engine host."
  value       = length(local.engine_vm_keys) > 0 ? oci_core_instance.linux[local.engine_vm_keys[0]].private_ip : null
}

output "kvm_host_public_ips" {
  description = "Map of KVM host VM name to public IP. Use as ansible_host for the kvm_hosts group."
  value       = { for k in local.kvm_host_vm_keys : k => oci_core_instance.linux[k].public_ip }
}

output "kvm_host_private_ips" {
  description = "Map of KVM host VM name to private IP (the address the Engine uses to reach the host)."
  value       = { for k in local.kvm_host_vm_keys : k => oci_core_instance.linux[k].private_ip }
}

output "nfs_public_ip" {
  description = "Public IP of the NFS storage server. Use as ansible_host for the nfs_server group."
  value       = length(local.nfs_vm_keys) > 0 ? oci_core_instance.linux[local.nfs_vm_keys[0]].public_ip : null
}

output "nfs_private_ip" {
  description = "Private IP of the NFS storage server (the address KVM hosts mount the export from)."
  value       = length(local.nfs_vm_keys) > 0 ? oci_core_instance.linux[local.nfs_vm_keys[0]].private_ip : null
}

output "ansible_inventory_hint" {
  description = "Ready-to-paste values for the Ansible inventory groups."
  value = {
    engine     = length(local.engine_vm_keys) > 0 ? oci_core_instance.linux[local.engine_vm_keys[0]].public_ip : null
    kvm_hosts  = { for k in local.kvm_host_vm_keys : k => oci_core_instance.linux[k].public_ip }
    nfs_server = length(local.nfs_vm_keys) > 0 ? oci_core_instance.linux[local.nfs_vm_keys[0]].public_ip : null
  }
}
