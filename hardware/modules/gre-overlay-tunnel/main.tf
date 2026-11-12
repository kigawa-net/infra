# EasyTier の Overlay のアドレスを両端にした GRE トンネルを作る(docs/frr-gre-overlay-design.md)。bao 側と control-plane 側の両方で使う。
# EasyTier は、宛先が Overlay のアドレスでも proxy_network でもないパケットを運ばない。Overlay のアドレスを両端にした GRE の中に入れると、
# EasyTier が運ぶのは Overlay のアドレス宛てだけになり、FRR(BGP)が決めた経路どおりに届く。
# tunnels が空(既定)なら、何もしない。modules/easytier とは別のモジュール(共有モジュールを変えると、それを使う全ノードが plan / apply の対象になるため)。
# ファイアウォールの許可(GRE、トンネル上の 179/tcp)も、このモジュールが iptables の INPUT の先頭に入れる(manage_firewall)。
# modules/overlay-firewall や modules/easytier(共有モジュール)は変えない。変えると、control-plane・bao の自動 apply の対象になるため。
locals {
  # 1 本は「インターフェース名,自分の Overlay,相手の Overlay,トンネル内のアドレス/長さ,MTU,相手のトンネル内のアドレス」。複数は ; で区切る。
  # 相手のトンネル内のアドレスは、/31 の、自分でない方(トンネル上の 179/tcp の許可の送信元)。
  tunnels_def = join(";", [
    for t in var.tunnels : join(",", [
      "gre-${t.name}", t.local, t.remote, t.address, tostring(t.mtu),
      cidrhost(t.address, 0) == split("/", t.address)[0] ? cidrhost(t.address, 1) : cidrhost(t.address, 0),
    ])
  ])
  script_env = "GO_TUNNELS='${local.tunnels_def}' GO_FIREWALL='${var.manage_firewall ? 1 : 0}' GO_OVERLAY_IFACE='${var.overlay_iface}'"
}

resource "null_resource" "gre_overlay" {
  count = length(var.tunnels) > 0 ? 1 : 0

  triggers = {
    host    = var.host
    tunnels = local.tunnels_def
    env     = "${var.manage_firewall}:${var.overlay_iface}"
    script  = filesha256("${path.module}/files/gre-overlay.sh")
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = file(var.ssh_private_key_file)
  }

  provisioner "file" {
    source      = "${path.module}/files/gre-overlay.sh"
    destination = "/tmp/gre-overlay.sh"
  }

  provisioner "remote-exec" {
    inline = [
      # root で接続するノードは sudo を使わず直接実行する。root でなければ sudo -S。
      "run() { env ${local.script_env} bash /tmp/gre-overlay.sh; }; if [ \"$(id -u)\" -eq 0 ]; then run; else echo '${var.sudo_password}' | sudo -S env ${local.script_env} bash /tmp/gre-overlay.sh; fi; rc=$?; rm -f /tmp/gre-overlay.sh; exit $rc",
    ]
  }
}
