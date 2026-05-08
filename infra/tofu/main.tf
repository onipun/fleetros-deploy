# OpenTofu — BYO-VPS bootstrap.
#
# This module does NOT provision a VPS. It assumes you have one already (any provider:
# Hetzner, OVH, Contabo, DigitalOcean droplet, etc.). It only:
#   1. Verifies SSH connectivity
#   2. Runs first-touch provisioning (creates `deploy` user, copies ssh key)
#   3. Outputs the IP in a shape `make tofu-inventory` can consume
#
# To plug in a real provider (e.g. Hetzner) later, replace the `null_resource` below
# with a `hcloud_server` resource and update outputs.

terraform {
  required_version = ">= 1.6"
  required_providers {
    null = { source = "hashicorp/null" }
  }
}

variable "vps_ip" {
  description = "Public IP of the rented VPS"
  type        = string
}

variable "vps_user" {
  description = "Initial SSH user (usually root)"
  type        = string
  default     = "root"
}

variable "ssh_private_key_path" {
  description = "Path to your SSH key for VPS access"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

resource "null_resource" "bootstrap" {
  connection {
    type        = "ssh"
    host        = var.vps_ip
    user        = var.vps_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      "id deploy >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo deploy",
      "echo 'deploy ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/deploy",
      "mkdir -p /home/deploy/.ssh",
      "cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys",
      "chown -R deploy:deploy /home/deploy/.ssh",
      "chmod 700 /home/deploy/.ssh && chmod 600 /home/deploy/.ssh/authorized_keys",
    ]
  }
}

output "vps_ip" {
  value = var.vps_ip
}

output "vps_user" {
  value = "deploy"
}
