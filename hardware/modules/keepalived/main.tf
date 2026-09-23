locals {
  keepalived_conf = <<-CONF
    vrrp_instance VI_1 {
        state ${var.state}
        interface ${var.interface}
        virtual_router_id ${var.virtual_router_id}
        priority ${var.priority}
        advert_int 1
        authentication {
            auth_type PASS
            auth_pass ${var.auth_pass}
        }
        virtual_ipaddress {
            ${var.virtual_ip}
        }
    }
    CONF
}

resource "null_resource" "keepalived" {
  triggers = {
    host           = var.host
    conf_hash      = sha256(local.keepalived_conf)
    script_version = "2"
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.keepalived_conf
    destination = "/tmp/keepalived.conf"
  }

  provisioner "remote-exec" {
    # 同一ホスト上で複数のnull_resourceのapt-getが並列実行される
    # (module.control_plane/module.wireguard/module.keepalived等)ことに加え、
    # OSのunattended-upgradesも不定期にdpkgロックを握るため、apt-get呼び出しの
    # 前にロックが空くまで待つ(hardware/modules/wireguardと同じ対応)。
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash -c 'for i in $(seq 1 60); do fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1 || break; sleep 5; done; DEBIAN_FRONTEND=noninteractive apt-get update -y'",
      "echo '${var.sudo_password}' | sudo -S bash -c 'for i in $(seq 1 60); do fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1 || break; sleep 5; done; DEBIAN_FRONTEND=noninteractive apt-get install -y keepalived'",
      "echo '${var.sudo_password}' | sudo -S mkdir -p /etc/keepalived",
      "echo '${var.sudo_password}' | sudo -S cp /tmp/keepalived.conf /etc/keepalived/keepalived.conf",
      "echo '${var.sudo_password}' | sudo -S systemctl enable --now keepalived",
      "echo '${var.sudo_password}' | sudo -S systemctl restart keepalived",
      "rm -f /tmp/keepalived.conf"
    ]
  }
}
