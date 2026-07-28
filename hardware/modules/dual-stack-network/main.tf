locals {
  netplan_config = <<-YAML
    network:
      version: 2
      ethernets:
        ${var.interface}:
          addresses:
          - ${var.primary_cidr}
          - ${var.secondary_cidr}
          nameservers:
            addresses:
    %{~for ns in var.nameservers}
            - ${ns}
    %{~endfor}
          routes:
          - to: default
            via: ${var.primary_gateway}
  YAML
}

resource "null_resource" "dual_stack_network" {
  triggers = {
    host           = var.host
    interface      = var.interface
    netplan_config = local.netplan_config
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.netplan_config
    destination = "/tmp/60-inuyama-migration.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash -c 'install -m 600 /tmp/60-inuyama-migration.yaml /etc/netplan/60-inuyama-migration.yaml && rm -f /tmp/60-inuyama-migration.yaml && netplan apply && sleep 2 && ip -4 addr show ${var.interface}'",
    ]
  }
}
