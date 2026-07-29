resource "null_resource" "wireguard" {
  triggers = {
    host              = var.host
    wireguard_address = var.wireguard_address
    server_endpoint   = var.server_endpoint
    server_public_key = sha256(var.server_public_key)
    allowed_ips       = join(",", var.server_allowed_ips)
    setup_version     = "3"
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = <<-SCRIPT
      #!/bin/bash
      set -eo pipefail
      export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      export DEBIAN_FRONTEND=noninteractive
      umask 077
      exec > >(tee -a /tmp/wireguard-setup.log) 2>&1

      apt-get update -y
      apt-get install -y wireguard

      install -d -m 711 /etc/wireguard

      if [ ! -f /etc/wireguard/privatekey ]; then
        wg genkey > /etc/wireguard/privatekey
        wg pubkey < /etc/wireguard/privatekey > /etc/wireguard/publickey
      fi
      chmod 600 /etc/wireguard/privatekey

      private_key=$(cat /etc/wireguard/privatekey)

      cat > /etc/wireguard/${var.wireguard_interface}.conf <<WG_EOF
      [Interface]
      Address = ${var.wireguard_address}
      PrivateKey = $private_key

      [Peer]
      PublicKey = ${var.server_public_key}
      AllowedIPs = ${join(", ", var.server_allowed_ips)}
      Endpoint = ${var.server_endpoint}
      PersistentKeepalive = ${var.persistent_keepalive}
      WG_EOF
      chmod 600 /etc/wireguard/${var.wireguard_interface}.conf

      systemctl enable wg-quick@${var.wireguard_interface}
      systemctl restart wg-quick@${var.wireguard_interface}

      echo "=== WireGuard status ==="
      wg show ${var.wireguard_interface}
      echo "=== Public key ==="
      cat /etc/wireguard/publickey
    SCRIPT
    destination = "/tmp/wireguard-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash /tmp/wireguard-setup.sh && rm -f /tmp/wireguard-setup.sh",
    ]
  }
}
