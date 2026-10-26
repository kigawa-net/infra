locals {
  # 2026-10-25 に k8s-worker1 の netplan(50-cloud-init.yaml)が書き換わり、デフォルトルートが無くなった。
  # kubelet が「no default routes found」で API サーバーに届かず、NotReady になり、worker1 上の
  # ArgoCD application-controller も止まった(infra#323)。50-cloud-init.yaml には触らず、
  # 別ファイルで、デフォルトルートとノードのアドレスを足す(netplan は、ファイル名順に、設定をマージする)。
  netplan_config = <<-YAML
    network:
      version: 2
      ethernets:
        ${var.interface}:
          addresses:
          - ${var.address_cidr}
          routes:
          - to: default
            via: ${var.gateway}
  YAML
}

resource "null_resource" "host_network" {
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
    destination = "/tmp/60-host-network.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash -c 'install -m 600 /tmp/60-host-network.yaml /etc/netplan/60-host-network.yaml && rm -f /tmp/60-host-network.yaml && netplan apply && sleep 2 && ip -4 addr show ${var.interface} && ip route show default'",
    ]
  }
}
