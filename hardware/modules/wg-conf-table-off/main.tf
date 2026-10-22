# 既存の wg-quick の設定に、`Table = off` と、必要な PostUp を、インターフェースを再起動せずに追記する(kigawa-net/infra#238)。
# 理由と、再起動しない理由は、files/wg-conf-table-off.sh のコメント。設定は、次に wg-quick が起動するとき(再起動)から効く。
locals {
  script = file("${path.module}/files/wg-conf-table-off.sh")
  # `<iface>|<PostUp のコマンド>`(コマンドが空なら、Table = off だけ)を、1 行ずつ
  spec = join("\n", flatten([
    for iface, cfg in var.interfaces : length(cfg.post_up) == 0 ? ["${iface}|"] : [for c in cfg.post_up : "${iface}|${c}"]
  ]))
}

resource "null_resource" "wg_conf_table_off" {
  triggers = {
    host        = var.host
    script_hash = sha256(local.script)
    spec_hash   = sha256(local.spec)
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.script
    destination = "/tmp/wg-conf-table-off.sh"
  }

  provisioner "file" {
    content     = local.spec
    destination = "/tmp/wg-conf-table-off.spec"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash -c 'SPEC=\"$(cat /tmp/wg-conf-table-off.spec)\" bash /tmp/wg-conf-table-off.sh'; rc=$?; rm -f /tmp/wg-conf-table-off.sh /tmp/wg-conf-table-off.spec; exit $rc",
    ]
  }
}
