resource "tls_private_key" "vm_ssh" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "vm_ssh_private_key" {
  content         = tls_private_key.vm_ssh.private_key_openssh
  filename        = local.ssh_private_key_path
  file_permission = "0600"
}
