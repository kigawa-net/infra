# systemd-networkd が、外部のポリシールールと経路を消さないようにする drop-in を置く(kigawa-net/infra#238)。
#
# networkd は、既定で、自分の管理外の ip rule と経路を、再起動のたびに消す。2026-10-21、k8s2 で、パッケージの更新に伴う networkd の再起動により、
# wg1 の PostUp で入れたポリシールール(IONOS 宛ての返信を k8s4 経由にする。#282)が消え、IONOS から API の VIP と k8s2 に届かなくなった。
# k8s4 は、最後の networkd の起動が 10/18 のままで、次の再起動で同じ目に遭う。
#
# **networkd は再起動しない**(files/networkd-keep-foreign.sh のコメント)。設定は、次の networkd の起動から効く。
locals {
  script = file("${path.module}/files/networkd-keep-foreign.sh")
}

resource "null_resource" "networkd_keep_foreign" {
  triggers = {
    host        = var.host
    script_hash = sha256(local.script)
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.script
    destination = "/tmp/networkd-keep-foreign.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash /tmp/networkd-keep-foreign.sh; rc=$?; rm -f /tmp/networkd-keep-foreign.sh; exit $rc",
    ]
  }
}
