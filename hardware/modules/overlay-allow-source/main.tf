# EasyTier の Overlay の特定の送信元からの TCP を、iptables の INPUT の先頭で許可する(CI のサブネットプロキシ経由の SSH 用)。
# modules/overlay-firewall(共有モジュール)は変えない。変えると、それを使う全ノードが plan / apply の対象になるため(gre-overlay-tunnel と同じ方針)。
# sources が空(既定)なら、何もしない。
resource "null_resource" "overlay_allow_source" {
  count = length(var.sources) > 0 ? 1 : 0

  triggers = {
    host    = var.host
    sources = join(" ", var.sources)
    script  = filesha256("${path.module}/files/overlay-allow-source.sh")
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    source      = "${path.module}/files/overlay-allow-source.sh"
    destination = "/tmp/overlay-allow-source.sh"
  }

  provisioner "remote-exec" {
    inline = [
      # root で接続するノードは sudo を使わず直接実行する。root でなければ sudo -S。
      "run() { env OA_SOURCES='${join(" ", var.sources)}' bash /tmp/overlay-allow-source.sh; }; if [ \"$(id -u)\" -eq 0 ]; then run; else echo '${var.sudo_password}' | sudo -S env OA_SOURCES='${join(" ", var.sources)}' bash /tmp/overlay-allow-source.sh; fi",
    ]
  }
}
