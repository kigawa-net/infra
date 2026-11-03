terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
    }
  }
}

locals {
  # gre-overlay-tunnel.sh の load_conf が読む設定(1 行 1 項目)。値は variables.tf で検証済み。
  tunnels_conf = "${join("\n", concat([
    "local ${var.overlay_address}",
    "mtu ${var.mtu}",
    "clamp_mss ${var.clamp_mss ? 1 : 0}",
    "firewall ${var.firewall}",
  ], [for p in var.peers : "peer ${p.name} ${p.overlay_address} ${p.local_tunnel_cidr} ${p.peer_tunnel_address}"]))}\n"
}

# 単一の null_resource。設定かスクリプトが変わったときだけ、再実行する(modules/overlay-firewall と同じ形)。
# スクリプトは install で /usr/local/sbin/gre-overlay に入り、gre-overlay.service が up / down を呼ぶ。
resource "null_resource" "gre_overlay" {
  triggers = {
    host        = var.host
    conf_hash   = sha256(local.tunnels_conf)
    script_hash = filesha256("${path.module}/files/gre-overlay-tunnel.sh")
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    source      = "${path.module}/files/gre-overlay-tunnel.sh"
    destination = "/tmp/gre-overlay-tunnel.sh"
  }

  provisioner "file" {
    content     = local.tunnels_conf
    destination = "/tmp/gre-overlay-tunnels.conf"
  }

  # root で接続するノードは sudo を使わず直接実行する。root でなければ sudo -S(frr-overlay-peer と同じ)。
  provisioner "remote-exec" {
    inline = [
      "run() { env GRE_SRC_CONF=/tmp/gre-overlay-tunnels.conf bash /tmp/gre-overlay-tunnel.sh install; }; if [ \"$(id -u)\" -eq 0 ]; then run; else printf '%s\\n' '${replace(var.sudo_password, "'", "'\"'\"'")}' | sudo -S env GRE_SRC_CONF=/tmp/gre-overlay-tunnels.conf bash /tmp/gre-overlay-tunnel.sh install; fi; rc=$?; rm -f /tmp/gre-overlay-tunnel.sh /tmp/gre-overlay-tunnels.conf; exit $rc",
    ]
  }
}
