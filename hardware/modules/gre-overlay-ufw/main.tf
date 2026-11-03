# bao 側(ufw を使うホスト)で、GRE トンネルのための受信を許可する(docs/frr-gre-overlay-design.md §6.2)。
#   - tun0 から、相手の Overlay のアドレスの gre(プロトコル 47)。Overlay の deny(modules/easytier の overlay_firewall)より前に入れる(insert 1)。
#   - トンネル(gre-<name>)の上の、相手のトンネルのアドレスからの 179/tcp。
# modules/easytier(共有モジュール)は変えない。置き換えると EasyTier が再起動し、OpenBao が seal されるため、ufw の規則だけを足す別のモジュールにしてある。
# peers が空(既定)なら、何もしない。足した規則は、外しても自動では消えない(README の ufw delete)。
locals {
  # 1 件は「名前,相手の Overlay,相手のトンネルのアドレス」。複数は ; で区切る。
  peers_def = join(";", [for p in var.peers : "${p.name},${p.overlay_address},${p.tunnel_address}"])
}

resource "null_resource" "gre_overlay_ufw" {
  count = length(var.peers) > 0 ? 1 : 0

  triggers = {
    host   = var.host
    peers  = local.peers_def
    script = filesha256("${path.module}/files/gre-overlay-ufw.sh")
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    source      = "${path.module}/files/gre-overlay-ufw.sh"
    destination = "/tmp/gre-overlay-ufw.sh"
  }

  provisioner "remote-exec" {
    inline = [
      # root で接続するノードは sudo を使わず直接実行する。root でなければ sudo -S。
      "run() { env GU_PEERS='${local.peers_def}' bash /tmp/gre-overlay-ufw.sh; }; if [ \"$(id -u)\" -eq 0 ]; then run; else echo '${var.sudo_password}' | sudo -S env GU_PEERS='${local.peers_def}' bash /tmp/gre-overlay-ufw.sh; fi; rc=$?; rm -f /tmp/gre-overlay-ufw.sh; exit $rc",
    ]
  }
}
