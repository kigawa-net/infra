# ufw を使わないホスト(control-plane など)で、EasyTier の Overlay からの受信を、iptables で許可リスト制にする(設計書 §7)。
# ufw が無効なホストでは、modules/easytier の overlay_firewall(ufw)は何も遮断しないため、こちらを使う。
# ルールは easytier.service の ExecStartPost(apply)/ ExecStopPost(remove)に結びつく。再起動後も残り、tunnel が無いときは外れる。
# modules/easytier とは別のモジュールにしてある(共有モジュールを変えると、それを使う全ノードが plan / apply の対象になるため)。
# easytier より先に適用すること(送信元アドレスで絞るので interface は要らず、Overlay が上がる前に遮断が入る)。
resource "null_resource" "overlay_firewall" {
  triggers = {
    host          = var.host
    overlay_cidr  = var.overlay_cidr
    overlay_allow = join(",", var.overlay_allow)
    script        = filesha256("${path.module}/files/overlay-fw-iptables.sh")
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    source      = "${path.module}/files/overlay-fw-iptables.sh"
    destination = "/tmp/overlay-fw-iptables.sh"
  }

  provisioner "remote-exec" {
    inline = [
      # root で接続するノードは sudo を使わず直接実行する。root でなければ sudo -S。
      "run() { env OF_CIDR='${var.overlay_cidr}' OF_ALLOW='${join(" ", var.overlay_allow)}' bash /tmp/overlay-fw-iptables.sh; }; if [ \"$(id -u)\" -eq 0 ]; then run; else echo '${var.sudo_password}' | sudo -S env OF_CIDR='${var.overlay_cidr}' OF_ALLOW='${join(" ", var.overlay_allow)}' bash /tmp/overlay-fw-iptables.sh; fi; rc=$?; rm -f /tmp/overlay-fw-iptables.sh; exit $rc",
    ]
  }
}
